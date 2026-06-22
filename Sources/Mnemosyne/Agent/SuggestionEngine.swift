import Foundation

/// A proactive thing the agent offers to do, derived from what's actually in the
/// knowledge base. Tapping it sends `query` to the agent (which then picks tools).
struct Suggestion: Identifiable, Sendable, Equatable {
    let id: String
    let title: String   // short chip label
    let query: String   // the full prompt sent to the agent on tap
    let icon: String    // SF Symbol

    init(id: String = UUID().uuidString, title: String, query: String, icon: String) {
        self.id = id; self.title = title; self.query = query; self.icon = icon
    }
}

/// Derives autonomous suggestions from the knowledge base — cheap and deterministic
/// (no LLM call), so it can run on every open and surface as chips in the Ask hero.
enum SuggestionEngine {
    /// Shown when the library is empty.
    static let empty: [Suggestion] = [
        .init(title: "Ingest a folder to begin", query: "How do I add my files to Mnemosyne?", icon: "folder.badge.plus"),
        .init(title: "What can you do?", query: "What can you do with my files once they're indexed?", icon: "sparkles"),
    ]

    /// Throttle for LIVE refresh during ingestion: recompute only when the count of
    /// newly-added items crosses a fresh bucket boundary (every `every` items), so
    /// chips emerge as content lands without recomputing on every single file.
    /// Pure → unit-testable; the view tracks `lastBucket` and updates it on refresh.
    static func shouldRefreshLive(added: Int, lastBucket: Int, running: Bool, every: Int = 5) -> Bool {
        guard running, added > 0, every > 0 else { return false }
        return (added / every) != lastBucket
    }

    /// The bucket index for a given added-count (caller stores this after refreshing).
    static func liveBucket(added: Int, every: Int = 5) -> Int { added / max(1, every) }

    /// Build suggestions from the store's structure (kinds, tags, citations, recency).
    static func suggestions(from store: KnowledgeStore, limit: Int = 6) async -> [Suggestion] {
        let items = (try? await store.allItems()) ?? []
        guard !items.isEmpty else { return empty }
        let tagsByItem = (try? await store.tagsByItem()) ?? [:]
        let tags = (try? await store.allTags()) ?? []
        let cited = (try? await store.mostCited(limit: 1)) ?? []

        var byKind: [ItemKind: Int] = [:]
        for it in items { byKind[it.kind, default: 0] += 1 }
        let untagged = items.filter { (tagsByItem[$0.id] ?? []).isEmpty }.count

        var out: [Suggestion] = []

        // Build something from the dominant kind.
        if let (kind, n) = byKind.max(by: { $0.value < $1.value }), n >= 4 {
            out.append(.init(title: "Build a dashboard of your \(kind.rawValue) files",
                             query: "Create a polished single-file HTML dashboard summarizing my \(kind.rawValue) files, grounded in their contents.",
                             icon: "rectangle.3.group"))
        }
        // Explore the library's dominant cross-document topic.
        if let theme = KeywordExtractor.libraryThemes(docs: items.map { "\($0.title) \($0.summary)" }, top: 1).first {
            out.append(.init(title: "Explore your top topic: \(theme.term)",
                             query: "Summarize what my library says about \(theme.term), with sources.",
                             icon: "sparkles.rectangle.stack"))
        }
        // Summarize the most-used label.
        if let top = tags.first {
            out.append(.init(title: "Summarize your '\(top.tag)' notes",
                             query: "Summarize everything labelled '\(top.tag)', with sources.",
                             icon: "text.alignleft"))
        }
        // Proactive tidy-up: detect near-duplicate labels and offer a one-tap merge.
        if let cluster = TagCleanup.nearDuplicateClusters(tags.map { ($0.tag, $0.count) }).first,
           let target = cluster.first {
            out.append(.init(title: "Merge \(cluster.count) similar labels",
                             query: "Merge the labels \(cluster.joined(separator: ", ")) into '\(target)'.",
                             icon: "tag.slash"))
        }
        // Tidy up untagged files.
        if untagged >= 3 {
            out.append(.init(title: "Organize \(untagged) untagged files",
                             query: "Look at my untagged files and suggest a sensible label for each.",
                             icon: "tag"))
        }
        // Dig into the most-referenced source.
        if let c = cited.first {
            out.append(.init(title: "Key points in \(short(c.item.title))",
                             query: "What are the key points in '\(c.item.title)'?", icon: "quote.bubble"))
        }
        // Recency.
        out.append(.init(title: "What did I save recently?",
                         query: "Summarize what I've added or changed recently.", icon: "clock"))
        // Web-augmented.
        out.append(.init(title: "Related work on the web",
                         query: "Search the web for recent developments related to the main topics in my library, and cite them.",
                         icon: "globe"))

        return Array(out.prefix(limit))
    }

    private static func short(_ s: String) -> String { s.count > 22 ? String(s.prefix(20)) + "…" : s }
}
