import XCTest
@testable import Mnemosyne

final class RelatedTests: XCTestCase {

    func testRelatedItemsRanksSimilarAndExcludesSelf() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Related-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        func add(_ id: String, _ text: String) async throws {
            let item = KnowledgeItem(id: id, path: "/tmp/\(id).md", title: id, kind: .markdown,
                                     contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date())
            let chunks = TextChunker.chunks(from: text).enumerated().map { i, t in
                Chunk(id: "\(id)#\(i)", itemID: id, ordinal: i, text: t, embedding: embedder.embed(t))
            }
            try await store.upsert(item: item, chunks: chunks)
        }

        try await add("vec1", "FAISS performs nearest neighbor search over dense vector embeddings.")
        try await add("vec2", "SQLite-vss indexes embeddings for similarity search and vector retrieval.")
        try await add("cooking", "Risotto needs warm stock added slowly with constant stirring.")

        let related = try await store.relatedItems(to: "vec1", k: 3)
        let ids = related.map(\.item.id)
        XCTAssertFalse(ids.contains("vec1"), "must exclude the item itself")
        XCTAssertEqual(related.first?.item.id, "vec2", "the other vector-DB note is most related")
        XCTAssertFalse(ids.isEmpty)
    }

    func testRelatedItemsEmptyForUnknownItem() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Related2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let related = try await store.relatedItems(to: "does-not-exist", k: 5)
        XCTAssertTrue(related.isEmpty)
    }
}
