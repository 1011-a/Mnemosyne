import XCTest
@testable import Mnemosyne

final class HybridSearchTests: XCTestCase {

    func testKeywordTermsFiltersStopwordsAndShort() {
        let terms = KnowledgeStore.keywordTerms("How does the XK-9920 error work?")
        XCTAssertTrue(terms.contains("xk"))
        XCTAssertTrue(terms.contains("9920"))
        XCTAssertTrue(terms.contains("error"))
        XCTAssertTrue(terms.contains("work"))
        XCTAssertFalse(terms.contains("how"), "stopword dropped")
        XCTAssertFalse(terms.contains("the"), "stopword dropped")
    }

    func testKeywordOverlap() {
        let terms: Set<String> = ["faiss", "vector", "9920"]
        XCTAssertEqual(KnowledgeStore.keywordOverlap(text: "FAISS indexes vectors", terms: terms), 2.0/3.0, accuracy: 0.001)
        XCTAssertEqual(KnowledgeStore.keywordOverlap(text: "nothing here", terms: terms), 0)
        XCTAssertEqual(KnowledgeStore.keywordOverlap(text: "x", terms: []), 0)
    }

    func testHybridSurfacesExactTermOverSemanticNeighbor() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Hybrid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        // Doc A contains the exact code; Doc B is semantically about disks but lacks it.
        let a = "The maintenance log notes that error code XK-9920 was logged on the array."
        let b = "Hard disk drives store data on spinning magnetic platters and can fail over time."
        try await store.upsert(item: KnowledgeItem(id: "a", path: "/tmp/a", title: "a", kind: .text,
                                                   contentHash: "a", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                               chunks: [Chunk(id: "a#0", itemID: "a", ordinal: 0, text: a, embedding: embedder.embed(a))])
        try await store.upsert(item: KnowledgeItem(id: "b", path: "/tmp/b", title: "b", kind: .text,
                                                   contentHash: "b", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                               chunks: [Chunk(id: "b#0", itemID: "b", ordinal: 0, text: b, embedding: embedder.embed(b))])

        let q = "XK-9920"
        let hybrid = try await store.search(vector: embedder.embed(q), queryText: q, k: 2)
        XCTAssertEqual(hybrid.first?.item.id, "a", "exact-term doc surfaces first with keyword boost")
    }

    func testEmptyQueryTextIsPureVector() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Hybrid2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let text = "vector embeddings nearest neighbor search"
        try await store.upsert(item: KnowledgeItem(id: "v", path: "/tmp/v", title: "v", kind: .text,
                                                   contentHash: "v", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                               chunks: [Chunk(id: "v#0", itemID: "v", ordinal: 0, text: text, embedding: embedder.embed(text))])
        // No queryText → behaves like before (still finds it).
        let hits = try await store.search(vector: embedder.embed("nearest neighbor"), k: 1)
        XCTAssertEqual(hits.first?.item.id, "v")
    }
}
