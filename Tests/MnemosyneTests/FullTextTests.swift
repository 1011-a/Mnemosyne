import XCTest
@testable import Mnemosyne

@MainActor
final class FullTextTests: XCTestCase {

    func testItemIDsMatchingContent() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FT-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        func add(_ id: String, _ text: String) async throws {
            try await store.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                                       contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date()),
                                   chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: text, embedding: [])])
        }
        try await add("a", "quarterly revenue grew on cloud GPU spend")
        try await add("b", "risotto needs warm stock")

        let hits = try await store.itemIDsMatchingContent("GPU")
        let pctHits = try await store.itemIDsMatchingContent("%")
        let blankHits = try await store.itemIDsMatchingContent("   ")
        XCTAssertEqual(hits, ["a"])
        XCTAssertTrue(pctHits.isEmpty, "literal % matches no content")
        XCTAssertTrue(blankHits.isEmpty)
    }

    func testFilteredIncludesContentOnlyMatches() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FT2-\(UUID().uuidString)")
        let store = try! KnowledgeStore(directory: dir)
        let vm = LibraryViewModel(store: store)
        // Title/summary/path do NOT contain "neptune"; only content does.
        vm.items = [KnowledgeItem(id: "x", path: "/tmp/doc.md", title: "doc.md", kind: .markdown,
                                  contentHash: "x", byteSize: 0, createdAt: Date(), modifiedAt: Date(),
                                  summary: "a summary")]
        vm.query = "neptune"
        vm.contentMatchIDs = []
        XCTAssertTrue(vm.filtered.isEmpty, "no field matches without content hit")
        vm.contentMatchIDs = ["x"]
        XCTAssertEqual(vm.filtered.map(\.id), ["x"], "content match surfaces the item")
    }
}
