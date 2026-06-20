import XCTest
@testable import Mnemosyne

final class DataMgmtTests: XCTestCase {

    private func storeWithData(_ embedder: Embedder) async throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DM-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        for id in ["a", "b"] {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "text \(id)", embedding: embedder.embed("text \(id)"))])
            try await store.setTags(["t"], forItem: id)
            try await store.recordCitations(itemIDs: [id])
        }
        return store
    }

    func testClearItemsWipesKnowledgeButKeepsThreads() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let store = try await storeWithData(embedder)
        try await store.upsertThread(ChatThread(id: "keep", title: "Keep me"))

        try await store.clearItems()
        let items = try await store.itemCount()
        let chunks = try await store.chunkCount()
        let tags = try await store.allTags()
        let cites = try await store.citationCounts()
        let threads = try await store.allThreads()
        XCTAssertEqual(items, 0)
        XCTAssertEqual(chunks, 0, "chunks cascade")
        XCTAssertTrue(tags.isEmpty, "tags cascade")
        XCTAssertTrue(cites.isEmpty, "citation counts cascade")
        XCTAssertEqual(threads.map(\.id), ["keep"], "chat threads are preserved")
    }

    func testReembedAllRecomputesAndKeepsSearchWorking() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let store = try await storeWithData(embedder)

        // Corrupt the stored embeddings, then rebuild.
        let n = try await store.reembedAll { _ in [] }     // no-op embeds skip
        XCTAssertEqual(n, 2, "reports chunk count processed")

        let rebuilt = try await store.reembedAll { embedder.embed($0) }
        XCTAssertEqual(rebuilt, 2)

        // Search still finds the right doc after rebuild.
        let hits = try await store.search(vector: embedder.embed("text a"), k: 1)
        XCTAssertEqual(hits.first?.item.id, "a")
    }
}
