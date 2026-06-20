import XCTest
@testable import Mnemosyne

final class TagsTests: XCTestCase {

    private func storeWithItems() async throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Tags-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        for id in ["a", "b", "c"] {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [])
        }
        return store
    }

    func testSetAndReadTagsNormalized() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["  Work ", "AI", "ai", "Project"], forItem: "a")
        let tags = try await store.tags(forItem: "a")
        XCTAssertEqual(tags, ["ai", "project", "work"], "lowercased, de-duped, sorted")
    }

    func testSetTagsReplaces() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["one", "two"], forItem: "a")
        try await store.setTags(["three"], forItem: "a")
        let tags = try await store.tags(forItem: "a")
        XCTAssertEqual(tags, ["three"])
    }

    func testAllTagsCountsAndTagsByItem() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["ai", "work"], forItem: "a")
        try await store.setTags(["ai"], forItem: "b")
        try await store.setTags(["cooking"], forItem: "c")

        let all = try await store.allTags()
        XCTAssertEqual(all.first?.tag, "ai")
        XCTAssertEqual(all.first?.count, 2)
        XCTAssertEqual(Set(all.map(\.tag)), ["ai", "work", "cooking"])

        let byItem = try await store.tagsByItem()
        XCTAssertEqual(byItem["a"].map(Set.init), Set(["ai", "work"]))
        XCTAssertEqual(byItem["b"], ["ai"])
        XCTAssertNil(byItem["nonexistent"])
    }

    func testTagsCascadeDeleteWithItem() async throws {
        let store = try await storeWithItems()
        try await store.setTags(["x"], forItem: "a")
        try await store.deleteItems(ids: ["a"])
        let byItem = try await store.tagsByItem()
        XCTAssertNil(byItem["a"], "tags should cascade-delete with their item")
    }

    func testThreadRename() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Rename-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        try await store.upsertThread(ChatThread(id: "t", title: "Old title"))
        try await store.updateThreadTitle(id: "t", title: "New title")
        let threads = try await store.allThreads()
        XCTAssertEqual(threads.first?.title, "New title")
    }
}
