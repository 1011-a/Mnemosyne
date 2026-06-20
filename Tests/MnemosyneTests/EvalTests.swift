import XCTest
@testable import Mnemosyne

/// Offline retrieval-quality guard. Seeds a small, topically-distinct corpus and
/// checks that paraphrased queries retrieve the right document. Catches
/// regressions in chunking / embedding / cosine ranking.
final class EvalTests: XCTestCase {

    private let corpus: [(id: String, text: String)] = [
        ("cooking", "To make a creamy risotto, add warm stock one ladle at a time and stir constantly until the rice is tender."),
        ("vectordb", "FAISS and SQLite-vss build indexes over dense embeddings to perform fast nearest-neighbor similarity search."),
        ("swiftui", "SwiftUI is a declarative UI framework for building macOS and iOS apps using views, state, and the Observable macro."),
        ("finance", "In the quarterly budget review, spending on cloud GPU instances rose twelve percent compared to last quarter."),
        ("travel", "A spring itinerary for Kyoto, Japan: visit the temples and gardens to see cherry blossoms in full bloom.")
    ]

    private let queries: [(q: String, expected: String)] = [
        ("how do I cook a creamy rice dish", "cooking"),
        ("fast nearest neighbor search over vector embeddings", "vectordb"),
        ("declarative framework for building mac apps", "swiftui"),
        ("how much did cloud GPU spending increase", "finance"),
        ("best places to see cherry blossoms in japan", "travel")
    ]

    func testRetrievalRecallAtOne() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable on host")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MnemoEval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        for doc in corpus {
            let item = KnowledgeItem(id: doc.id, path: "/tmp/\(doc.id).md", title: doc.id, kind: .markdown,
                                     contentHash: doc.id, byteSize: 0, createdAt: Date(), modifiedAt: Date())
            let chunks = TextChunker.chunks(from: doc.text).enumerated().map { i, t in
                Chunk(id: "\(doc.id)#\(i)", itemID: doc.id, ordinal: i, text: t, embedding: embedder.embed(t))
            }
            try await store.upsert(item: item, chunks: chunks)
        }

        var hitsAt1 = 0
        var reciprocalRankSum = 0.0
        for (q, expected) in queries {
            let results = try await store.search(vector: embedder.embed(q), k: 5, maxPerItem: 1)
            let ids = results.map(\.item.id)
            if ids.first == expected { hitsAt1 += 1 }
            if let rank = ids.firstIndex(of: expected) { reciprocalRankSum += 1.0 / Double(rank + 1) }
        }
        let recall = Double(hitsAt1) / Double(queries.count)
        let mrr = reciprocalRankSum / Double(queries.count)
        print("EVAL recall@1=\(recall)  MRR=\(String(format: "%.3f", mrr))  (\(hitsAt1)/\(queries.count))")

        // Guard against ranking regressions. On-device embeddings comfortably
        // clear this bar today; alert us if a change drops it.
        XCTAssertGreaterThanOrEqual(recall, 0.6, "retrieval recall@1 regressed to \(recall)")
        XCTAssertGreaterThanOrEqual(mrr, 0.7, "retrieval MRR regressed to \(mrr)")
    }
}
