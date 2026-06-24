import Foundation

/// Library-analytics tool handlers — collection-wide stats, health, duplicate/near-duplicate
/// detection, theme and language distribution, kind/date/tag filters, activity trends, most-cited,
/// briefings, and library/tag summaries — extracted from `ToolAgent`'s main `handleTool` switch to
/// keep that file focused. Store-coupled (aggregate across the whole store), so they live in an
/// `extension ToolAgent` rather than migrating to Fathom. `handleLibraryTool` returns nil when `name`
/// isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleLibraryTool(_ name: String, args: String, citationOffset: Int,
                           onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "tag_stats":
            onStatus("Analyzing labels…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let total = (try? await store.itemCount()) ?? byItem.count
            let labelled = byItem.values.filter { !$0.isEmpty }.count
            let cov = TagStats.coverage(labelled: labelled, total: total)
            return (TagStats.summary(Array(byItem.values)) + "\nCoverage — \(cov.text).", [])

        case "library_health":
            onStatus("Checking library health…")
            let total = (try? await store.itemCount()) ?? 0
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let labelled = byItem.values.filter { !$0.isEmpty }.count
            let untagged = Swift.max(0, total - labelled)
            let tags = ((try? await store.allTags()) ?? []).map { ($0.tag, $0.count) }
            let clusters = TagCleanup.nearDuplicateClusters(tags)
            return (Self.libraryHealthReport(total: total, labelled: labelled,
                                             untagged: untagged, nearDupClusters: clusters), [])

        case "find_duplicates":
            onStatus("Scanning for duplicate files…")
            let items = (try? await store.allItems()) ?? []
            let groups = Self.duplicateGroups(items.map { (title: $0.title, hash: $0.contentHash) })
            guard !groups.isEmpty else { return ("No exact duplicate files found.", []) }
            let text = groups.prefix(20).map { "• \($0.joined(separator: " = "))" }.joined(separator: "\n")
            return ("\(groups.count) set(s) of identical files:\n\(text)", [])

        case "find_similar_titles":
            onStatus("Scanning for near-duplicate filenames…")
            let items = (try? await store.allItems()) ?? []
            let groups = Self.similarTitleGroups(items.map(\.title))
            guard !groups.isEmpty else { return ("No near-duplicate filenames found.", []) }
            let text = groups.prefix(20).map { "• \($0.joined(separator: " ~ "))" }.joined(separator: "\n")
            return ("\(groups.count) set(s) of similarly-named files (may be versions/copies):\n\(text)", [])

        case "library_themes":
            onStatus("Finding dominant topics…")
            let items = (try? await store.allItems()) ?? []
            let themes = KeywordExtractor.libraryThemes(docs: items.map { "\($0.title) \($0.summary)" })
            guard !themes.isEmpty else { return ("Not enough overlapping content to surface clear themes yet.", []) }
            return ("Top themes across \(items.count) file(s): "
                    + themes.map { "\($0.term) (\($0.count))" }.joined(separator: ", "), [])

        case "find_by_kind":
            guard let raw = arg("kind") else { return ("Missing 'kind'.", []) }
            guard let kind = Self.matchKind(raw) else {
                return ("Unknown file kind '\(raw)'. Try pdf, image, markdown, text, code, webpage, email, or word.", [])
            }
            onStatus("Finding \(kind.rawValue) files…")
            let matched = ((try? await store.allItems()) ?? []).filter { $0.kind == kind }
            return matched.isEmpty ? ("No \(kind.rawValue) files in the library.", [])
                : ("\(matched.count) \(kind.rawValue) file(s): " + matched.prefix(40).map(\.title).joined(separator: "; "), [])

        case "library_languages":
            onStatus("Detecting languages across the library…")
            let cap = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 300, 1), 1000)
            let items = ((try? await store.allItems()) ?? []).prefix(cap)
            guard !items.isEmpty else { return ("The knowledge base is empty.", []) }
            var codes: [String] = []
            for it in items {
                // Sample the first chunk's text — enough signal for language ID, cheap.
                let sample = ((try? await store.chunkTexts(forItem: it.id)) ?? []).first ?? ""
                if let r = LanguageDetector.detect(sample) { codes.append(r.dominant) }
            }
            let dist = Self.languageDistribution(codes)
            guard !dist.isEmpty else { return ("Couldn't detect languages (too little text in \(items.count) sampled file(s)).", []) }
            let total = dist.reduce(0) { $0 + $1.count }
            let parts = dist.map { d -> String in
                let pct = Int((Double(d.count) / Double(total) * 100).rounded())
                return "\(LanguageDetector.name(for: d.language)) \(d.count) (\(pct)%)"
            }
            return ("Languages across \(total) sampled file(s): " + parts.joined(separator: ", "), [])

        case "catch_me_up":
            onStatus("Putting together your briefing…")
            let days = Int(arg("days") ?? "") ?? 7
            let now = Date()
            let items = (try? await store.allItems()) ?? []
            let changed = Self.changedSince(items, Self.changeThreshold(days: days, since: nil, now: now)).map(\.title)
            let due = ReminderStore.dueSoon(reminders.all(), within: days, now: now).map(\.title)
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let untagged = items.filter { (byItem[$0.id] ?? []).isEmpty }.count
            return (Self.briefing(totalItems: items.count, windowDays: days,
                                  changedRecently: changed, dueReminders: due, untagged: untagged), [])

        case "library_stats":
            onStatus("Counting the knowledge base…")
            let items = (try? await store.allItems()) ?? []
            let chunks = (try? await store.chunkCount()) ?? 0
            var byKind: [String: Int] = [:]
            for it in items { byKind[it.kind.rawValue, default: 0] += 1 }
            let kinds = byKind.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return ("\(items.count) items, \(chunks) chunks. By kind — \(kinds).", [])

        case "most_cited":
            onStatus("Finding your most-referenced files…")
            let n = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 5, 1), 25)
            let top = (try? await store.mostCited(limit: n)) ?? []
            guard !top.isEmpty else { return ("No files have been cited yet — ask a question and I'll start tracking which sources you rely on.", []) }
            let list = top.map { "\($0.item.title) (\($0.count) citation\($0.count == 1 ? "" : "s"))" }.joined(separator: "; ")
            return ("Most-referenced files: \(list)", [])

        case "activity_trend":
            onStatus("Measuring activity…")
            let days = Swift.min(Swift.max(Int(arg("days") ?? "") ?? 30, 1), 90)
            let buckets = (try? await store.ingestActivity(days: days)) ?? []
            return ("Activity (last \(days) days): " + Self.activitySummary(buckets), [])

        case "summarize_library":
            onStatus("Summarizing your library…")
            let items = (try? await store.allItems()) ?? []
            let chunks = (try? await store.chunkCount()) ?? 0
            let tags = (try? await store.allTags()) ?? []
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let untagged = items.filter { (byItem[$0.id] ?? []).isEmpty }.count
            return (Self.librarySummary(items: items, topTags: tags.map { ($0.tag, $0.count) },
                                        untagged: untagged, chunks: chunks), [])

        case "find_by_tag":
            guard let tag = arg("tag") else { return ("Missing 'tag'.", []) }
            onStatus("Finding files labelled '\(tag)'…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let items = (try? await store.allItems()) ?? []
            let want = tag.lowercased()
            let matches = items.filter { (byItem[$0.id] ?? []).contains { $0.lowercased() == want } }
            return matches.isEmpty ? ("No files carry the label '\(tag)'.", [])
                : ("\(matches.count) file(s) labelled '\(tag)': " + matches.prefix(30).map(\.title).joined(separator: "; "), [])

        case "summarize_tag":
            guard let tag = arg("tag") else { return ("Missing 'tag'.", []) }
            onStatus("Summarizing '\(tag)'…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let items = (try? await store.allItems()) ?? []
            let want = tag.lowercased()
            let matches = items.filter { (byItem[$0.id] ?? []).contains { $0.lowercased() == want } }
            guard !matches.isEmpty else { return ("No files carry the label '\(tag)' to summarize.", []) }
            var sources: [(title: String, path: String, itemID: String, body: String)] = []
            for it in matches.prefix(12) {
                let body = String(((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: " ").prefix(800))
                sources.append((it.title, it.path, it.id, body))
            }
            return Self.tagSummaryFraming(tag: tag, sources: sources, citationOffset: citationOffset)

        default:
            return nil
        }
    }
}
