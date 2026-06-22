import Foundation

/// Drives the pipeline per file: detect → (incremental skip) → extract → chunk
/// → embed → persist. Runs off the main actor; reports to `IngestProgress`.
actor Ingestor {
    /// Per-file work caps so one giant file can't stall the queue: at most ~1M
    /// chars of text, and at most this many chunks embedded.
    static let maxChars = 1_000_000
    static let maxChunks = 1200

    let store: KnowledgeStore
    let embedder: Embedder
    private let ollama: OllamaClient
    /// Read at the start of each run so toggles (multimodal, auto-tag) apply live.
    private let settings: SettingsStore

    init(store: KnowledgeStore, embedder: Embedder, ollama: OllamaClient, settings: SettingsStore) {
        self.store = store; self.embedder = embedder
        self.ollama = ollama; self.settings = settings
    }

    private func currentExtractor() async -> ContentExtractor {
        let order = settings.visionEngineOrder
        let primary = order.first ?? .gemma
        var multimodal = settings.multimodal
        if multimodal, primary == .gemma {
            // If Gemma is the primary but isn't reachable, stay multimodal as long as a
            // fallback engine is configured — the extractor will switch to it per file.
            let gemmaReady = await ollama.status().isReady
            multimodal = gemmaReady || order.contains { $0 != .gemma }
        }
        return ContentExtractor(ollama: ollama, multimodal: multimodal,
                                visionEngine: primary, engineOrder: order)
    }

    /// Human-readable label for the (often slow) extraction step, shown live so a
    /// file being read by Gemma/OCR doesn't look frozen.
    static func activityLabel(for kind: ItemKind, vision: VisionEngine) -> String {
        let eng = vision.activityName
        let external = vision.usesExternalCLI
        switch kind {
        case .image:            return "Looking at image — \(eng)…"
        case .pdf:              return external ? "Reading PDF — \(eng)…" : "Reading PDF…"
        case .iwork:            return external ? "Reading document — \(eng)…" : "Reading document…"
        case .audioTranscript:  return "Transcribing audio…"
        case .wordDoc:          return "Reading document…"
        default:                return "Reading…"
        }
    }

    /// Scan a folder and ingest everything new or changed.
    func ingestFolder(_ root: URL, progress: IngestProgress) async {
        await MainActor.run { progress.scanning() }
        let urls = FolderScanner.scan(root)
        await ingest(urls: urls, progress: progress)
    }

    /// Force re-extract + re-embed a single file, even if unchanged (e.g. after
    /// the user edits the source).
    func reingest(path: String, progress: IngestProgress) async {
        let url = URL(fileURLWithPath: path)
        await MainActor.run { progress.beginJob(total: 1) }
        let extractor = await currentExtractor()
        IngestDebugLog.write("reingest begin total=1 engine=\(extractor.visionEngine.rawValue) multimodal=\(extractor.multimodal) file=\(url.lastPathComponent)")
        do {
            try await ingestOne(url, title: url.lastPathComponent, progress: progress,
                                extractor: extractor, force: true)
        } catch {
            await MainActor.run { progress.tickSkipped(url.lastPathComponent) }
        }
        await MainActor.run { progress.endJob() }
    }

    /// Remove items whose source file no longer exists on disk. Returns the count pruned.
    @discardableResult
    func pruneDeleted() async -> Int {
        guard let items = try? await store.allItems() else { return 0 }
        let gone = items.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id)
        guard !gone.isEmpty else { return 0 }
        try? await store.deleteItems(ids: gone)
        return gone.count
    }

    /// How many files to process at once for external CLI engines. Their per-file
    /// calls are dominated by subprocess startup + network wait, so running a few
    /// concurrently amortises it. Gemma is local-GPU-bound, so it stays at 1.
    static let externalCliLanes = 4

    /// Ingest an explicit list of files.
    func ingest(urls: [URL], progress: IngestProgress) async {
        await MainActor.run { progress.beginJob(total: urls.count) }
        let extractor = await currentExtractor()
        let engineAtStart = extractor.visionEngine
        let lanes = engineAtStart.usesExternalCLI ? Self.externalCliLanes : 1
        IngestDebugLog.write("ingest begin total=\(urls.count) engineAtStart=\(engineAtStart.rawValue) multimodal=\(extractor.multimodal) lanes=\(lanes)")
        if lanes <= 1 {
            for url in urls {
                if Task.isCancelled { break }
                await ingestOneSafe(url, progress: progress, extractor: extractor)
            }
        } else {
            // Bounded-concurrency worker pool: keep `lanes` files in flight, refilling
            // as each finishes (the off-actor `extract` external CLI call overlaps lanes).
            var iter = urls.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<lanes {
                    guard let u = iter.next() else { break }
                    group.addTask { await self.ingestOneSafe(u, progress: progress, extractor: extractor) }
                }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    guard let u = iter.next() else { continue }
                    group.addTask { await self.ingestOneSafe(u, progress: progress, extractor: extractor) }
                }
            }
        }
        IngestDebugLog.write("ingest end total=\(urls.count)")
        await MainActor.run { progress.endJob() }
    }

    /// One file, never throwing — a failure counts as processed so the run continues.
    private func ingestOneSafe(_ url: URL, progress: IngestProgress, extractor: ContentExtractor) async {
        let title = url.lastPathComponent
        do {
            try await ingestOne(url, title: title, progress: progress, extractor: extractor)
        } catch {
            await MainActor.run {
                progress.appendLog("⚠", "failed  \(title)", .warn)
                progress.tickSkipped(title)
            }
        }
    }

    /// Import bookmarks (e.g. from a Safari `Bookmarks.plist`) as `.webpage`
    /// knowledge items. Each is a synthetic item keyed by its URL — no file on
    /// disk — with searchable text (title + url + host + slug words).
    func ingestBookmarks(_ bookmarks: [Bookmark], progress: IngestProgress) async {
        await MainActor.run { progress.beginJob(total: bookmarks.count) }
        for b in bookmarks {
            if Task.isCancelled { break }
            let body = "\(b.title)\n\(WebLocExtractor.readable(b.url))"
            let itemID = Hashing.sha256("bookmark:" + b.url)
            let now = Date()
            let item = KnowledgeItem(
                id: itemID, path: b.url, title: b.title, kind: .webpage,
                contentHash: Hashing.sha256(body), byteSize: Int64(body.utf8.count),
                createdAt: now, modifiedAt: now, summary: String(body.prefix(220)))
            let chunks = TextChunker.chunks(from: body).enumerated().compactMap { (i, t) -> Chunk? in
                let v = embedder.embed(t)
                guard !v.isEmpty else { return nil }
                return Chunk(id: "\(itemID)#\(i)", itemID: itemID, ordinal: i, text: t, embedding: v)
            }
            guard !chunks.isEmpty else { await MainActor.run { progress.tickSkipped(b.title) }; continue }
            do {
                try await store.upsert(item: item, chunks: chunks)
                await MainActor.run { progress.tickAdded(b.title) }
            } catch {
                await MainActor.run { progress.tickSkipped(b.title) }
            }
        }
        await MainActor.run { progress.endJob() }
    }

    private func ingestOne(_ url: URL, title: String, progress: IngestProgress,
                           extractor: ContentExtractor, force: Bool = false) async throws {
        guard let kind = TypeDetector.kind(for: url) else {
            await MainActor.run { progress.tickSkipped(title) }; return
        }

        // Cheap file signature drives incremental skip (avoids re-running Gemma/OCR).
        let vals = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let size = Int64(vals.fileSize ?? 0)
        let mtime = vals.contentModificationDate ?? .distantPast
        let created = vals.creationDate ?? mtime
        let signature = Hashing.sha256("\(url.path)|\(size)|\(mtime.timeIntervalSince1970)")

        let priorHash = try? await store.contentHash(forPath: url.path)
        if !force, priorHash == signature {
            await MainActor.run { progress.tickSkipped(title) }; return
        }
        let isNew = (priorHash == nil)   // brand-new item → safe to auto-tag

        // Announce the slow step BEFORE it runs — extracting an image or a scanned
        // PDF means a ~15–20s Gemma call, so without this the file looks frozen.
        let activity = Self.activityLabel(for: kind, vision: extractor.visionEngine)
        IngestDebugLog.write("extract begin engine=\(extractor.visionEngine.rawValue) kind=\(kind.rawValue) file=\(title)")
        await MainActor.run {
            progress.note(title, activity)
            progress.appendLog("→", "\(activity)  \(title)", .work)
        }
        let text = try await extractor.extract(url: url, kind: kind)
        IngestDebugLog.write("extract end engine=\(extractor.visionEngine.rawValue) chars=\(text.count) file=\(title)")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            await MainActor.run { progress.tickSkipped(title) }; return
        }
        // Bound the work per file so ONE very large file can't stall the whole
        // queue (the start of a document is the most representative; fully
        // indexing a 100 MB file is impractical for a personal KB).
        let bounded = trimmed.count > Self.maxChars ? String(trimmed.prefix(Self.maxChars)) : trimmed

        let itemID = Hashing.sha256(url.path)   // stable per location; upsert replaces on change
        let item = KnowledgeItem(
            id: itemID, path: url.path, title: title, kind: kind,
            contentHash: signature, byteSize: size, createdAt: created, modifiedAt: mtime,
            summary: String(bounded.prefix(220)))

        let pieces = Array(TextChunker.chunks(from: bounded).prefix(Self.maxChunks))
        var chunks: [Chunk] = []
        chunks.reserveCapacity(pieces.count)
        for (i, t) in pieces.enumerated() {
            if Task.isCancelled { break }
            let v = embedder.embed(t)
            if v.isEmpty { continue }
            chunks.append(Chunk(id: "\(itemID)#\(i)", itemID: itemID, ordinal: i, text: t, embedding: v))
            // Per-chunk progress so a big file shows movement, not a frozen 1%.
            if pieces.count > 150, i % 50 == 0 {
                let done = i, total = pieces.count
                await MainActor.run { progress.note(title, "Embedding \(done)/\(total)") }
            }
        }
        guard !chunks.isEmpty else {
            await MainActor.run { progress.tickSkipped(title) }; return
        }

        try await store.upsert(item: item, chunks: chunks)

        // Auto-tag brand-new items from their folder structure (never clobbers
        // tags a user added, since changed files aren't "new").
        if isNew, settings.autoTag {
            let autoTags = AutoTagger.tags(for: url)
            if !autoTags.isEmpty { try? await store.setTags(autoTags, forItem: itemID) }
        }
        await MainActor.run { progress.tickAdded(title) }
    }
}
