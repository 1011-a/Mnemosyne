import XCTest
@testable import Mnemosyne

final class StatsTests: XCTestCase {

    func testEmptyStats() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Stats0-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        let s = try await store.stats()
        XCTAssertEqual(s.itemCount, 0)
        XCTAssertEqual(s.totalBytes, 0)
        XCTAssertTrue(s.byKind.isEmpty)
        XCTAssertNil(s.oldest)
    }

    func testAggregateStats() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        func add(_ id: String, kind: ItemKind, bytes: Int64) async throws {
            let item = KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: kind,
                                     contentHash: id, byteSize: bytes, createdAt: Date(), modifiedAt: Date())
            try await store.upsert(item: item, chunks: [
                Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "text \(id)", embedding: embedder.embed("text \(id)"))
            ])
        }
        try await add("a", kind: .pdf, bytes: 100)
        try await add("b", kind: .pdf, bytes: 200)
        try await add("c", kind: .markdown, bytes: 50)
        try await store.setTags(["x", "y"], forItem: "a")
        try await store.upsertThread(ChatThread(id: "t", title: "Chat"))

        let s = try await store.stats()
        XCTAssertEqual(s.itemCount, 3)
        XCTAssertEqual(s.chunkCount, 3)
        XCTAssertEqual(s.threadCount, 1)
        XCTAssertEqual(s.tagCount, 2)
        XCTAssertEqual(s.totalBytes, 350)
        XCTAssertEqual(s.byKind.first?.kind, .pdf, "pdf is the most common kind")
        XCTAssertEqual(s.byKind.first?.count, 2)
        XCTAssertEqual(s.maxKindCount, 2)
        XCTAssertNotNil(s.oldest)
    }
}
