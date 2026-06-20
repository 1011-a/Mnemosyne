import XCTest
@testable import Mnemosyne

@MainActor
final class BulkTagTests: XCTestCase {

    private func makeVM() async throws -> (LibraryViewModel, KnowledgeStore) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Bulk-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        for id in ["a", "b", "c"] {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [])
        }
        let vm = LibraryViewModel(store: store)
        vm.items = try await store.allItems()
        return (vm, store)
    }

    func testSelectionToggling() async throws {
        let (vm, _) = try await makeVM()
        vm.toggleSelectionMode()
        XCTAssertTrue(vm.selectionMode)
        vm.toggleSelected("a"); vm.toggleSelected("b")
        XCTAssertEqual(vm.selection, ["a", "b"])
        vm.toggleSelected("a")
        XCTAssertEqual(vm.selection, ["b"])
        vm.selectAllFiltered()
        XCTAssertEqual(vm.selection, ["a", "b", "c"])
        vm.toggleSelectionMode()  // exiting clears
        XCTAssertTrue(vm.selection.isEmpty)
    }

    func testBulkAddAndRemoveTag() async throws {
        let (vm, store) = try await makeVM()
        vm.selection = ["a", "b"]
        vm.addTagToSelection("Project X")
        XCTAssertEqual(vm.tagsByItem["a"], ["project x"], "normalized + applied in-memory")
        XCTAssertEqual(vm.tagsByItem["b"], ["project x"])
        XCTAssertNil(vm.tagsByItem["c"], "unselected item untouched")

        // Persisted to the store.
        try await waitFor { (try? await store.tags(forItem: "a")) == ["project x"] }

        vm.removeTagFromSelection("project x")
        XCTAssertEqual(vm.tagsByItem["a"], [])
        try await waitFor { (try? await store.tags(forItem: "a")) == [] }
    }

    func testBulkTagIgnoresEmptyAndNoSelection() async throws {
        let (vm, _) = try await makeVM()
        vm.selection = []
        vm.addTagToSelection("x")   // no selection → no-op
        XCTAssertTrue(vm.tagsByItem.isEmpty)
        vm.selection = ["a"]
        vm.addTagToSelection("   ") // empty → no-op
        XCTAssertNil(vm.tagsByItem["a"])
    }

    private func waitFor(timeout: TimeInterval = 2, _ cond: @escaping () async -> Bool) async throws {
        let start = Date()
        while !(await cond()) {
            if Date().timeIntervalSince(start) > timeout { XCTFail("condition not met"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
