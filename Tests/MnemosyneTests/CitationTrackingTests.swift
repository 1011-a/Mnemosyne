import XCTest
@testable import Mnemosyne

final class CitationTrackingTests: XCTestCase {

    private func storeWithItems() async throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cite-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        for id in ["a", "b", "c"] {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [])
        }
        return store
    }

    func testRecordAndRankCitations() async throws {
        let store = try await storeWithItems()
        try await store.recordCitations(itemIDs: ["a", "b"])
        try await store.recordCitations(itemIDs: ["a", "a", "c"])  // a cited again (twice in one answer)

        let top = try await store.mostCited(limit: 5)
        let counts = Dictionary(uniqueKeysWithValues: top.map { ($0.item.id, $0.count) })
        XCTAssertEqual(counts["a"], 3)
        XCTAssertEqual(counts["b"], 1)
        XCTAssertEqual(counts["c"], 1)
        XCTAssertEqual(top.first?.item.id, "a", "most-cited ranks first")
    }

    func testRecordIgnoresEmptyIDs() async throws {
        let store = try await storeWithItems()
        try await store.recordCitations(itemIDs: ["", "", "b"])
        let top = try await store.mostCited()
        XCTAssertEqual(top.map(\.item.id), ["b"])
    }

    func testCitationsCascadeDeleteWithItem() async throws {
        let store = try await storeWithItems()
        try await store.recordCitations(itemIDs: ["a"])
        try await store.deleteItems(ids: ["a"])
        let top = try await store.mostCited()
        XCTAssertFalse(top.contains { $0.item.id == "a" }, "citation counts cascade with the item")
    }

    func testStatsIncludesTopCited() async throws {
        let store = try await storeWithItems()
        try await store.recordCitations(itemIDs: ["b", "b"])
        let stats = try await store.stats()
        XCTAssertEqual(stats.topCited.first?.item.id, "b")
        XCTAssertEqual(stats.topCited.first?.count, 2)
    }

    func testCitationCarriesItemID() {
        let c = Citation(index: 1, title: "t", path: "/p", snippet: "s", itemID: "xyz")
        XCTAssertEqual(c.itemID, "xyz")
    }
}
