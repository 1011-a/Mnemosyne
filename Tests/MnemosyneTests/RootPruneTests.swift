import XCTest
@testable import Mnemosyne

final class RootPruneTests: XCTestCase {

    func testDeleteItemsUnderPrunesOnlyThatFolder() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        func add(_ id: String, path: String) async throws {
            try await store.upsert(
                item: KnowledgeItem(id: id, path: path, title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                chunks: [])
        }
        try await add("a", path: "/Users/me/Projects/Alpha/notes.md")
        try await add("b", path: "/Users/me/Projects/Alpha/sub/deep.md")
        try await add("c", path: "/Users/me/Projects/Beta/plan.md")

        let removed = try await store.deleteItemsUnder(pathPrefix: "/Users/me/Projects/Alpha")
        XCTAssertEqual(removed, 2, "both Alpha items (incl. nested) removed")
        let remaining = try await store.allItems().map(\.id)
        XCTAssertEqual(remaining, ["c"], "Beta is untouched")
    }

    func testDeleteItemsUnderEscapesWildcards() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Prune2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        // A literal "%" in a folder name must not act as a wildcard.
        try await store.upsert(
            item: KnowledgeItem(id: "x", path: "/tmp/100%done/file.txt", title: "x", kind: .text,
                                contentHash: "x", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
            chunks: [])
        try await store.upsert(
            item: KnowledgeItem(id: "y", path: "/tmp/100Xdone/file.txt", title: "y", kind: .text,
                                contentHash: "y", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
            chunks: [])
        let removed = try await store.deleteItemsUnder(pathPrefix: "/tmp/100%done")
        let remaining = try await store.allItems().map(\.id)
        XCTAssertEqual(removed, 1, "only the literal %-named folder, not a wildcard match")
        XCTAssertEqual(remaining, ["y"])
    }
}
