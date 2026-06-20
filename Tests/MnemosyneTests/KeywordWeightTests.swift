import XCTest
@testable import Mnemosyne

final class KeywordWeightTests: XCTestCase {

    func testSettingDefaultAndClamp() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "KW-\(UUID().uuidString)")!)
        XCTAssertEqual(s.keywordWeight, 0.3, accuracy: 0.0001)
        s.keywordWeight = 0.8
        XCTAssertEqual(s.keywordWeight, 0.8, accuracy: 0.0001)
        s.keywordWeight = 5      // clamps to 1
        XCTAssertEqual(s.keywordWeight, 1.0, accuracy: 0.0001)
        s.keywordWeight = -2     // clamps to 0
        XCTAssertEqual(s.keywordWeight, 0.0, accuracy: 0.0001)
    }

    func testWeightZeroDisablesKeywordBoost() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KW2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        let a = "The maintenance log records error code ZQ-7731 on the controller."
        let b = "Hard drives store data on spinning platters and may fail over time."
        try await store.upsert(item: KnowledgeItem(id: "a", path: "/tmp/a", title: "a", kind: .text,
                               contentHash: "a", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                               chunks: [Chunk(id: "a#0", itemID: "a", ordinal: 0, text: a, embedding: embedder.embed(a))])
        try await store.upsert(item: KnowledgeItem(id: "b", path: "/tmp/b", title: "b", kind: .text,
                               contentHash: "b", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                               chunks: [Chunk(id: "b#0", itemID: "b", ordinal: 0, text: b, embedding: embedder.embed(b))])

        let q = "ZQ-7731"
        // With a strong keyword weight the exact-term doc wins.
        let boosted = try await store.search(vector: embedder.embed(q), queryText: q, k: 2, keywordWeight: 0.5)
        XCTAssertEqual(boosted.first?.item.id, "a")

        // With weight 0 the keyword signal is off → ranking is pure cosine
        // (scores for both are computed without the boost; "a" no longer guaranteed).
        let pure0 = try await store.search(vector: embedder.embed(q), queryText: q, k: 2, keywordWeight: 0)
        let pureNoText = try await store.search(vector: embedder.embed(q), k: 2)
        XCTAssertEqual(pure0.map(\.item.id), pureNoText.map(\.item.id),
                       "weight 0 should match pure-vector ordering")
    }
}
