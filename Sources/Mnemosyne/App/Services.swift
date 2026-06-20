import Foundation

/// Composition root — builds and holds the app's long-lived services.
/// Created once at launch and injected into views via the SwiftUI environment.
@MainActor
final class Services {
    let config: Config
    let store: KnowledgeStore
    let embedder: Embedder
    let deepSeek: DeepSeekClient
    let ollama: OllamaClient
    let ingestor: Ingestor
    let rag: RAGAgent
    let toolAgent: ToolAgent
    let roots = RootsStore()
    let settings: SettingsStore
    let progress = IngestProgress()

    /// Whether the local Gemma multimodal model answered at boot.
    private(set) var multimodalAvailable = false
    /// Live FSEvents watching state (surfaced in Settings).
    private(set) var isWatching = false
    private(set) var watchedCount = 0
    private var watcher: FolderWatcher?

    /// True when launched by XCUITest — use an isolated temp DB with synthetic
    /// items (no real files) so the tests never touch TCC-protected folders.
    let isUITest = ProcessInfo.processInfo.arguments.contains("--uitest")

    init() throws {
        let settings = SettingsStore()
        self.settings = settings
        let config = Config.load(settings: settings)
        self.config = config
        let storeDir = ProcessInfo.processInfo.arguments.contains("--uitest")
            ? FileManager.default.temporaryDirectory.appendingPathComponent("MnemosyneUITest", isDirectory: true)
            : nil
        self.store = try KnowledgeStore(directory: storeDir)
        self.embedder = Embedder()
        self.deepSeek = DeepSeekClient(config: config)
        self.ollama = OllamaClient(config: config)
        // Extractor starts assuming multimodal; refined by `probe()` after launch.
        self.ingestor = Ingestor(store: store, embedder: embedder, ollama: ollama, settings: settings)
        self.rag = RAGAgent(store: store, embedder: embedder, deepSeek: deepSeek,
                            topK: settings.topK, temperature: settings.temperature,
                            queryRewrite: settings.queryRewrite)
        self.toolAgent = ToolAgent(store: store, embedder: embedder, deepSeek: deepSeek,
                                   topK: max(4, settings.topK - 2), temperature: settings.temperature)
    }

    /// A DeepSeek client using the CURRENTLY-selected model.
    private func currentDeepSeek() -> DeepSeekClient {
        DeepSeekClient(config: config.overriding(model: settings.model)
            .overriding(deepSeekKey: effectiveDeepSeekKey))
    }

    var effectiveDeepSeekKey: String {
        if config.deepSeekKeySource == .environment { return config.deepSeekKey }
        return settings.deepSeekKey
    }

    var isDeepSeekConfigured: Bool { !effectiveDeepSeekKey.isEmpty }

    var deepSeekKeySource: String {
        if config.deepSeekKeySource == .environment { return "environment" }
        if !settings.deepSeekKey.isEmpty { return "macOS Keychain" }
        return "missing"
    }

    /// Build agents from the CURRENT settings so changes apply to the next message
    /// without a relaunch.
    func makeRAG() -> RAGAgent {
        RAGAgent(store: store, embedder: embedder, deepSeek: currentDeepSeek(),
                 topK: settings.topK, temperature: settings.temperature,
                 keywordWeight: Float(settings.keywordWeight), queryRewrite: settings.queryRewrite)
    }
    func makeToolAgent() -> ToolAgent {
        ToolAgent(store: store, embedder: embedder, deepSeek: currentDeepSeek(),
                  topK: max(4, settings.topK - 2), temperature: settings.temperature,
                  keywordWeight: Float(settings.keywordWeight))
    }

    /// Fresh chat session. Agents are rebuilt per-message from live settings.
    func makeChat() -> ChatViewModel {
        ChatViewModel(makeRAG: { [self] in makeRAG() },
                      makeTool: { [self] in makeToolAgent() },
                      store: store, settings: settings)
    }

    /// Probe local Ollama; rebuild the ingestor's extractor to match reality.
    func probe() async {
        let reachable = await ollama.isReachable()
        multimodalAvailable = reachable
    }

    /// Refresh the persisted "items in your knowledge base" figure shown on the
    /// Ingest screen — so a reopened app reflects what's already indexed instead
    /// of an alarming "0 added".
    func refreshLibraryCount() async {
        if let n = try? await store.itemCount() { progress.libraryItems = n }
    }

    func ingest(folder: URL) {
        roots.add(folder)
        Task.detached { [ingestor, progress] in
            await ingestor.ingestFolder(folder, progress: progress)
        }
    }

    /// Seed the isolated `--uitest` store with synthetic items whose paths don't
    /// exist on disk, so the Library/detail tests render (icons, not thumbnails)
    /// without ever reading a real, TCC-protected file.
    func seedUITestLibrary() async {
        let now = Date()
        let fixtures: [(String, ItemKind, String)] = [
            ("/tmp/uitest-notes.txt", .text, "Meeting notes about the quarterly plan and budget."),
            ("/tmp/uitest-paper.pdf", .pdf, "A research paper on on-device vector search."),
            ("/tmp/uitest-diagram.png", .image, "A diagram of the system architecture."),
        ]
        for (path, kind, text) in fixtures {
            let id = "uit-" + Hashing.sha256(path).prefix(8)
            let item = KnowledgeItem(id: String(id), path: path,
                                     title: URL(fileURLWithPath: path).lastPathComponent, kind: kind,
                                     contentHash: String(id), byteSize: 100,
                                     createdAt: now, modifiedAt: now, summary: text)
            let chunk = Chunk(id: "\(id)#0", itemID: String(id), ordinal: 0, text: text, embedding: [])
            try? await store.upsert(item: item, chunks: [chunk])
        }
    }

    /// Import a Safari `Bookmarks.plist` the user picked: parse the tree and
    /// ingest each bookmark as a `.webpage` knowledge item.
    func importBookmarks(from plist: URL) {
        Task.detached { [ingestor, progress] in
            let data = (try? Data(contentsOf: plist)) ?? Data()
            let bookmarks = SafariBookmarksParser.parse(data)
            await ingestor.ingestBookmarks(bookmarks, progress: progress)
        }
    }

    /// Ingest a mixed drop of files and folders. Folders are remembered as roots
    /// (and watched); loose files are ingested directly.
    func ingestDropped(_ urls: [URL]) {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(url) } else { files.append(url) }
        }
        for folder in folders { roots.add(folder) }
        Task.detached { [ingestor, progress] in
            for folder in folders { await ingestor.ingestFolder(folder, progress: progress) }
            if !files.isEmpty {
                await ingestor.ingest(urls: files, progress: progress)
            }
        }
        if !folders.isEmpty { startWatching() }
    }

    /// Re-scan every previously-ingested folder on launch and prune deleted
    /// files. The ingestor's incremental skip means unchanged files cost almost
    /// nothing. Then begin live watching.
    func resumeIndexing() {
        let saved = roots.roots
        guard !saved.isEmpty else { return }
        Task.detached { [ingestor, progress] in
            await ingestor.pruneDeleted()
            for folder in saved where FileManager.default.fileExists(atPath: folder.path) {
                await ingestor.ingestFolder(folder, progress: progress)
            }
        }
        startWatching()
    }

    /// Watch saved roots via FSEvents; auto re-ingest changes, prune deletions.
    func startWatching() {
        let live = roots.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !live.isEmpty else { return }
        let w = FolderWatcher { [weak self] paths in
            Task { @MainActor in self?.handleChanges(paths) }
        }
        w.start(paths: live)
        watcher = w
        isWatching = true
        watchedCount = live.count
    }

    func stopWatching() {
        watcher?.stop(); watcher = nil; isWatching = false; watchedCount = 0
    }

    /// Force re-ingest a single file (re-extract + re-embed).
    func reingest(path: String) {
        Task.detached { [ingestor, progress] in
            await ingestor.reingest(path: path, progress: progress)
        }
    }

    /// Stop watching a folder, forget it, and prune the items ingested from it.
    func removeRoot(_ url: URL) {
        roots.remove(url)
        let path = url.standardizedFileURL.path
        Task.detached { [store] in _ = try? await store.deleteItemsUnder(pathPrefix: path) }
        stopWatching()
        startWatching()
    }

    /// Forget all ingested data and the watched folders (a clean reset).
    func clearKnowledge() {
        stopWatching()
        for root in roots.roots { roots.remove(root) }
        Task.detached { [store] in try? await store.clearItems() }
    }

    /// Re-embed every chunk from its stored text (no file re-reading needed).
    func rebuildIndex() {
        Task.detached { [store, embedder] in
            _ = try? await store.reembedAll { embedder.embed($0) }
        }
    }

    private func handleChanges(_ paths: [String]) {
        let toIngest = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && TypeDetector.kind(for: $0) != nil }
        Task.detached { [ingestor, progress] in
            await ingestor.pruneDeleted()
            if !toIngest.isEmpty { await ingestor.ingest(urls: toIngest, progress: progress) }
        }
    }
}
