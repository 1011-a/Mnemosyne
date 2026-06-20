import XCTest
@testable import Mnemosyne

final class SavedSearchTests: XCTestCase {

    func testKindsSerializationRoundtrip() {
        let s = SavedSearch(name: "x", query: "q", kinds: [.pdf, .markdown], tag: "work")
        XCTAssertEqual(s.kindsField, "pdf,markdown")
        XCTAssertEqual(SavedSearch.parseKinds(s.kindsField), [.pdf, .markdown])
        XCTAssertEqual(SavedSearch.parseKinds("pdf,bogus,image"), [.pdf, .image], "unknown kinds dropped")
    }

    func testDefaultName() {
        XCTAssertEqual(SavedSearch.defaultName(query: "vectors", kinds: [.pdf], tag: "ai"),
                       "#ai · pdf · \"vectors\"")
        XCTAssertEqual(SavedSearch.defaultName(query: "", kinds: [], tag: nil), "All items")
    }

    func testStoreRoundtripAndDelete() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SS-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        let a = SavedSearch(id: "1", name: "PDFs", query: "", kinds: [.pdf], tag: nil)
        let b = SavedSearch(id: "2", name: "AI notes", query: "embeddings", kinds: [.markdown], tag: "ai")
        try await store.saveSearch(a)
        try await store.saveSearch(b)

        let loaded = try await store.allSavedSearches()
        XCTAssertEqual(loaded.map(\.id), ["1", "2"])
        XCTAssertEqual(loaded[1].tag, "ai")
        XCTAssertEqual(loaded[1].query, "embeddings")
        XCTAssertEqual(loaded[0].kinds, [.pdf])
        XCTAssertNil(loaded[0].tag)

        try await store.deleteSavedSearch(id: "1")
        let after = try await store.allSavedSearches()
        XCTAssertEqual(after.map(\.id), ["2"])
    }

    @MainActor
    func testViewModelSaveAndApply() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SSVM-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let vm = LibraryViewModel(store: store)

        // Set a filter and save it.
        vm.query = "search"
        vm.activeKinds = [.pdf]
        vm.activeTag = "work"
        XCTAssertTrue(vm.hasActiveFilter)
        vm.saveCurrentFilter()

        // Poll until the async save lands.
        try await waitFor { vm.savedSearches.count == 1 }
        let saved = vm.savedSearches[0]

        // Clear, then re-apply.
        vm.query = ""; vm.activeKinds = []; vm.activeTag = nil
        XCTAssertFalse(vm.hasActiveFilter)
        vm.apply(saved)
        XCTAssertEqual(vm.query, "search")
        XCTAssertEqual(vm.activeKinds, [.pdf])
        XCTAssertEqual(vm.activeTag, "work")
    }

    @MainActor
    private func waitFor(timeout: TimeInterval = 2, _ cond: @escaping () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("condition not met"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
