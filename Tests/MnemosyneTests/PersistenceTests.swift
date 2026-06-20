import XCTest
@testable import Mnemosyne

final class PersistenceTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MnemoTest-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testRootsAddDedupeAndOrder() {
        let store = RootsStore(defaults: isolatedDefaults())
        let a = URL(fileURLWithPath: "/Users/me/Docs")
        let b = URL(fileURLWithPath: "/Users/me/Notes")

        store.add(a)
        store.add(b)
        XCTAssertEqual(store.roots.map(\.path), ["/Users/me/Notes", "/Users/me/Docs"])

        // Re-adding moves to front without duplicating.
        store.add(a)
        XCTAssertEqual(store.roots.map(\.path), ["/Users/me/Docs", "/Users/me/Notes"])
        XCTAssertEqual(store.roots.count, 2)

        store.remove(a)
        XCTAssertEqual(store.roots.map(\.path), ["/Users/me/Notes"])
    }

    func testChunkTextsRoundtrip() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoChunks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        let item = KnowledgeItem(id: "x", path: "/tmp/x.md", title: "x.md", kind: .markdown,
                                 contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        let chunks = (0..<3).map { i in
            Chunk(id: "x#\(i)", itemID: "x", ordinal: i, text: "chunk number \(i)", embedding: embedder.embed("chunk \(i)"))
        }
        try await store.upsert(item: item, chunks: chunks)

        let texts = try await store.chunkTexts(forItem: "x")
        XCTAssertEqual(texts, ["chunk number 0", "chunk number 1", "chunk number 2"])
    }
}
