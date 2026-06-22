import XCTest
@testable import Mnemosyne

final class SuggestionEngineTests: XCTestCase {

    private func store() throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sugg-\(UUID().uuidString)", isDirectory: true)
        return try KnowledgeStore(directory: dir)
    }

    func testEmptyLibraryGivesOnboardingSuggestions() async throws {
        let s = try store()
        let sug = await SuggestionEngine.suggestions(from: s)
        XCTAssertEqual(sug, SuggestionEngine.empty)
    }

    func testDerivesSuggestionsFromContent() async throws {
        let s = try store()
        let e = Embedder()
        // 5 PDFs (dominant kind) + 4 untagged, one tagged + cited.
        for i in 0..<5 {
            let id = "pdf\(i)"
            try await s.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).pdf", title: "\(id).pdf",
                kind: .pdf, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "doc \(i)", embedding: e.embed("doc \(i)"))])
        }
        try await s.setTags(["research"], forItem: "pdf0")
        try await s.recordCitations(itemIDs: ["pdf0", "pdf0"])

        let suggestions = await SuggestionEngine.suggestions(from: s)
        let titles = suggestions.map(\.title).joined(separator: " | ")
        XCTAssertTrue(titles.lowercased().contains("dashboard"), "dominant kind → dashboard build: \(titles)")
        XCTAssertTrue(titles.lowercased().contains("research"), "top tag → summarize: \(titles)")
        XCTAssertTrue(titles.lowercased().contains("untagged"), "untagged files → organize: \(titles)")
    }

    func testLiveRefreshThrottleCrossesBuckets() {
        // Not running, or nothing added yet ⇒ never refresh.
        XCTAssertFalse(SuggestionEngine.shouldRefreshLive(added: 12, lastBucket: 0, running: false))
        XCTAssertFalse(SuggestionEngine.shouldRefreshLive(added: 0, lastBucket: -1, running: true))
        // First item lands in bucket 0 (added 3, every 5) — differs from initial -1 ⇒ refresh.
        XCTAssertTrue(SuggestionEngine.shouldRefreshLive(added: 3, lastBucket: -1, running: true))
        // Same bucket ⇒ no churn.
        XCTAssertFalse(SuggestionEngine.shouldRefreshLive(added: 4, lastBucket: 0, running: true))
        // Crossing into bucket 1 (added 5) ⇒ refresh.
        XCTAssertTrue(SuggestionEngine.shouldRefreshLive(added: 5, lastBucket: 0, running: true))
        XCTAssertEqual(SuggestionEngine.liveBucket(added: 5), 1)
        XCTAssertEqual(SuggestionEngine.liveBucket(added: 14), 2)
    }

    func testNearDuplicateLabelsSurfaceMergeSuggestion() async throws {
        let s = try store()
        let e = Embedder()
        for (i, label) in ["note", "notes", "Notes"].enumerated() {
            let id = "n\(i)"
            try await s.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).md", title: "\(id).md",
                kind: .markdown, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "x", embedding: e.embed("x"))])
            try await s.setTags([label], forItem: id)
        }
        let sug = await SuggestionEngine.suggestions(from: s)
        XCTAssertTrue(sug.contains { $0.query.lowercased().hasPrefix("merge the labels") },
                      "near-duplicate labels should surface a merge suggestion: \(sug.map(\.title))")
    }

    func testSurfacesTopThemeSuggestion() async throws {
        let s = try store()
        let e = Embedder()
        // Titles share the term "vector" across ≥2 files ⇒ it's a library theme.
        for (i, t) in ["vector database notes", "vector search guide", "cooking recipes"].enumerated() {
            let id = "d\(i)"
            try await s.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).md", title: t, kind: .markdown,
                contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: t, embedding: e.embed(t))])
        }
        let queries = await SuggestionEngine.suggestions(from: s).map(\.query).joined(separator: " | ")
        XCTAssertTrue(queries.lowercased().contains("vector"),
                      "the dominant cross-document topic should be offered: \(queries)")
    }

    func testSuggestionQueriesAreNonEmpty() async throws {
        let s = try store()
        let e = Embedder()
        try await s.upsert(item: KnowledgeItem(id: "a", path: "/tmp/a.md", title: "a.md", kind: .markdown,
            contentHash: "a", byteSize: 1, createdAt: Date(), modifiedAt: Date()),
            chunks: [Chunk(id: "a#0", itemID: "a", ordinal: 0, text: "x", embedding: e.embed("x"))])
        for sug in await SuggestionEngine.suggestions(from: s) {
            XCTAssertFalse(sug.title.isEmpty); XCTAssertFalse(sug.query.isEmpty); XCTAssertFalse(sug.icon.isEmpty)
        }
    }
}
