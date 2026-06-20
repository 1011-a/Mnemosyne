import XCTest
@testable import Mnemosyne

@MainActor
final class TagRenameDeleteTests: XCTestCase {

    private func storeWithItems() async throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TRD-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        for id in ["a", "b", "c"] {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [])
        }
        return store
    }

    func testRenameTagSimple() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["draft"], forItem: "a")
        try await store.setTags(["draft"], forItem: "b")
        try await store.renameTag(from: "Draft", to: "Final")  // case-normalized
        let a = try await store.tags(forItem: "a")
        let b = try await store.tags(forItem: "b")
        let all = try await store.allTags().map(\.tag)
        XCTAssertEqual(a, ["final"])
        XCTAssertEqual(b, ["final"])
        XCTAssertFalse(all.contains("draft"))
    }

    func testRenameTagMergesWithoutDuplicate() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["old", "keep"], forItem: "a")  // a has both
        try await store.setTags(["old"], forItem: "b")          // b has only old
        try await store.renameTag(from: "old", to: "keep")
        let a = try await store.tags(forItem: "a")
        let b = try await store.tags(forItem: "b")
        let keepCount = try await store.allTags().first { $0.tag == "keep" }?.count
        XCTAssertEqual(a, ["keep"], "no duplicate keep")
        XCTAssertEqual(b, ["keep"])
        XCTAssertEqual(keepCount, 2)
    }

    func testRenameTagIgnoresNoops() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["x"], forItem: "a")
        try await store.renameTag(from: "x", to: "x")   // same → no-op
        try await store.renameTag(from: "", to: "y")    // empty → no-op
        let a = try await store.tags(forItem: "a")
        XCTAssertEqual(a, ["x"])
    }

    @MainActor
    func testBulkDeleteRemovesItemsAndData() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["t"], forItem: "a")
        try await store.recordCitations(itemIDs: ["a"])
        let vm = LibraryViewModel(store: store)
        vm.items = try await store.allItems()
        vm.tagsByItem = try await store.tagsByItem()
        vm.citationCounts = try await store.citationCounts()

        vm.selection = ["a", "b"]
        vm.deleteSelection()
        XCTAssertEqual(vm.items.map(\.id), ["c"], "selected items removed from VM")
        XCTAssertNil(vm.tagsByItem["a"])
        XCTAssertTrue(vm.selection.isEmpty)

        let start = Date()
        var remaining = try await store.itemCount()
        while remaining != 1 {
            if Date().timeIntervalSince(start) > 2 { XCTFail("delete did not persist"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
            remaining = try await store.itemCount()
        }
        let finalIDs = try await store.allItems().map(\.id)
        XCTAssertEqual(finalIDs, ["c"])
    }

    @MainActor
    func testExportIncludesReasoning() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ExpR-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        let vm = ChatViewModel(makeRAG: { fatalError() }, makeTool: { fatalError() },
                               store: store, settings: SettingsStore(defaults: UserDefaults(suiteName: "er-\(UUID())")!))
        vm.messages = [
            ChatMessage(role: .user, content: "why?"),
            ChatMessage(role: .assistant, content: "Because.", model: "deepseek-reasoner",
                        reasoning: "step 1, step 2")
        ]
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.contains("<summary>Reasoning</summary>"))
        XCTAssertTrue(md.contains("step 1, step 2"))
    }
}
