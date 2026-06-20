import XCTest
@testable import Mnemosyne

final class StoreTests: XCTestCase {

    func testChunkerSplitsAndOverlaps() {
        let para = String(repeating: "Vector databases store embeddings. ", count: 120)
        let chunks = TextChunker.chunks(from: para, targetChars: 400, overlapChars: 80)
        XCTAssertGreaterThan(chunks.count, 1, "long text should produce multiple chunks")
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    func testHashingIsStable() {
        XCTAssertEqual(Hashing.sha256("hello"), Hashing.sha256("hello"))
        XCTAssertNotEqual(Hashing.sha256("hello"), Hashing.sha256("world"))
    }

    func testEmbedderProducesNormalizedVectors() throws {
        let e = Embedder()
        try XCTSkipUnless(e.isAvailable, "NLEmbedding model unavailable on this host")
        let v = e.embed("FAISS is a library for similarity search.")
        XCTAssertFalse(v.isEmpty)
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 0.001, "vectors must be L2-normalized")
    }

    func testStoreRoundtripAndSemanticSearch() async throws {
        let e = Embedder()
        try XCTSkipUnless(e.isAvailable, "NLEmbedding model unavailable on this host")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoTest-\(UUID().uuidString)", isDirectory: true)
        let store = try KnowledgeStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        func ingest(_ id: String, _ title: String, _ text: String) async throws {
            let item = KnowledgeItem(id: id, path: "/tmp/\(id)", title: title, kind: .text,
                                     contentHash: Hashing.sha256(text), byteSize: Int64(text.utf8.count),
                                     createdAt: Date(), modifiedAt: Date())
            let chunks = TextChunker.chunks(from: text).enumerated().map { (i, t) in
                Chunk(id: "\(id)#\(i)", itemID: id, ordinal: i, text: t, embedding: e.embed(t))
            }
            try await store.upsert(item: item, chunks: chunks)
        }

        try await ingest("a", "Cooking", "A risotto needs slow-added warm stock and constant stirring.")
        try await ingest("b", "Databases", "FAISS and SQLite-vss index vector embeddings for nearest-neighbor search.")

        let count = try await store.itemCount()
        XCTAssertEqual(count, 2)
        let chunkCount = try await store.chunkCount()
        XCTAssertGreaterThan(chunkCount, 0)

        let q = e.embed("how do I search embeddings quickly")
        let hits = try await store.search(vector: q, k: 2)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.item.id, "b", "DB chunk should outrank the cooking chunk")

        // Re-ingesting same path should not duplicate items.
        try await ingest("b", "Databases", "FAISS and SQLite-vss index vector embeddings for nearest-neighbor search.")
        let countAfter = try await store.itemCount()
        XCTAssertEqual(countAfter, 2)
    }
}
