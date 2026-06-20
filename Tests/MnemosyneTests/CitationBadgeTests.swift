import XCTest
@testable import Mnemosyne

@MainActor
final class CitationBadgeTests: XCTestCase {

    private func storeWithItems() async throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Badge-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        for id in ["a", "b", "c"] {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [])
        }
        return store
    }

    func testCitationCountsMap() async throws {
        let store = try await storeWithItems()
        try await store.recordCitations(itemIDs: ["a", "a", "b"])
        let counts = try await store.citationCounts()
        XCTAssertEqual(counts["a"], 2)
        XCTAssertEqual(counts["b"], 1)
        XCTAssertNil(counts["c"], "uncited items absent from the map")
    }

    func testLibrarySortByCited() async throws {
        let store = try await storeWithItems()
        try await store.recordCitations(itemIDs: ["b", "b", "b", "c"])
        let vm = LibraryViewModel(store: store)
        vm.items = try await store.allItems()
        vm.citationCounts = try await store.citationCounts()
        vm.sort = .cited
        XCTAssertEqual(vm.filtered.first?.id, "b", "most-cited item sorts first")
        XCTAssertEqual(vm.filtered.map(\.id).prefix(2).last, "c")
    }
}
