import XCTest
@testable import Mnemosyne

/// Regression for "a Chinese-named doc exists but search says 'not found'": the
/// English embedder can't vectorise a Chinese query, so retrieval must still work
/// via the keyword signal — and a distinctive name must outrank common words.
/// Uses entirely synthetic, non-personal fixture text.
final class ChineseSearchTests: XCTestCase {

    func testKeywordTermsSegmentsChinese() {
        let terms = KnowledgeStore.keywordTerms("彩虹猫的所有相关内容")
        XCTAssertTrue(terms.contains("彩虹"), "CJK must be bigram-segmented, got \(terms)")
    }

    func testChineseDocIsRetrievedByKeywordWhenVectorIsEmpty() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoCN-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let embedder = Embedder()

        func add(_ id: String, _ text: String) async throws {
            let item = KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .wordDoc,
                                     contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date())
            let c = Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: text, embedding: embedder.embed(text))
            try await store.upsert(item: item, chunks: [c])
        }
        // The target — the only doc mentioning the distinctive (fictional) name 彩虹猫.
        try await add("target", "彩虹猫工作室的项目说明，所有相关内容的示例归档资料。")
        // Decoys that share the COMMON words (内容/相关/所有) but not the name.
        for i in 0..<5 { try await add("decoy\(i)", "这是第\(i)份示例文档，包含所有相关内容的说明与测试。") }

        // A pure-Chinese query — the English embedder's vector (if any) is noise, so
        // retrieval must lean on the keyword/bigram signal.
        let q = "彩虹猫的所有相关内容"
        let hits = try await store.search(vector: embedder.embed(q), queryText: q, k: 8)
        XCTAssertFalse(hits.isEmpty, "keyword retrieval must find the doc (was returning nothing)")
        XCTAssertEqual(hits.first?.item.id, "target",
                       "the distinctive name 彩虹猫 must outrank docs that only share common words")
    }
}
