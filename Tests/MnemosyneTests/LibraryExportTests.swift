import XCTest
@testable import Mnemosyne

@MainActor
final class LibraryExportTests: XCTestCase {

    private func item(_ id: String, _ title: String, kind: ItemKind, size: Int64, ageDays: Double) -> KnowledgeItem {
        let date = Date(timeIntervalSinceNow: -ageDays * 86_400)
        return KnowledgeItem(id: id, path: "/tmp/\(title)", title: title, kind: kind,
                             contentHash: id, byteSize: size, createdAt: date, modifiedAt: date,
                             summary: "summary of \(title)")
    }

    private func vmWithItems() throws -> LibraryViewModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LibVM-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        let vm = LibraryViewModel(store: store)
        vm.items = [
            item("a", "alpha.pdf", kind: .pdf, size: 300, ageDays: 1),
            item("b", "beta.md", kind: .markdown, size: 100, ageDays: 3),
            item("c", "gamma.pdf", kind: .pdf, size: 500, ageDays: 2),
            item("d", "delta.png", kind: .image, size: 900, ageDays: 5)
        ]
        return vm
    }

    func testKindCountsGroupAndOrder() throws {
        let vm = try vmWithItems()
        let counts = Dictionary(uniqueKeysWithValues: vm.kindCounts.map { ($0.kind, $0.count) })
        XCTAssertEqual(counts[.pdf], 2)
        XCTAssertEqual(counts[.markdown], 1)
        XCTAssertEqual(counts[.image], 1)
        XCTAssertEqual(vm.kindCounts.first?.kind, .pdf, "most frequent kind sorts first")
    }

    func testKindFilter() throws {
        let vm = try vmWithItems()
        vm.toggleKind(.pdf)
        XCTAssertEqual(Set(vm.filtered.map(\.id)), ["a", "c"])
        vm.toggleKind(.image)
        XCTAssertEqual(Set(vm.filtered.map(\.id)), ["a", "c", "d"])
        vm.activeKinds.removeAll()
        XCTAssertEqual(vm.filtered.count, 4)
    }

    func testSortOrders() throws {
        let vm = try vmWithItems()
        vm.sort = .size
        XCTAssertEqual(vm.filtered.map(\.id), ["d", "c", "a", "b"])   // 900,500,300,100
        vm.sort = .name
        XCTAssertEqual(vm.filtered.map(\.title).first, "alpha.pdf")
        vm.sort = .recent
        XCTAssertEqual(vm.filtered.first?.id, "a", "most recent first (1 day old)")
    }

    func testDuplicateSets() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Dup-\(UUID().uuidString)")
        let vm = LibraryViewModel(store: try KnowledgeStore(directory: dir))
        func it(_ id: String, _ title: String, hash: String) -> KnowledgeItem {
            KnowledgeItem(id: id, path: "/\(title)", title: title, kind: .text,
                          contentHash: hash, byteSize: 1, createdAt: Date(), modifiedAt: Date())
        }
        vm.items = [it("1", "a.txt", hash: "h1"), it("2", "a-copy.txt", hash: "h1"),
                    it("3", "b.txt", hash: "h2")]   // b is unique
        let sets = vm.duplicateSets
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first, ["a-copy.txt", "a.txt"], "the dup pair, sorted")
    }

    func testDuplicateItemGroupsAndDelete() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DupV-\(UUID().uuidString)")
        let vm = LibraryViewModel(store: try KnowledgeStore(directory: dir))
        func mk(_ id: String, _ title: String, hash: String) -> KnowledgeItem {
            KnowledgeItem(id: id, path: "/\(title)", title: title, kind: .text,
                          contentHash: hash, byteSize: 1, createdAt: Date(), modifiedAt: Date())
        }
        vm.items = [mk("1", "a.txt", hash: "h"), mk("2", "a-copy.txt", hash: "h"),
                    mk("3", "uniq.txt", hash: "x")]
        let groups = vm.duplicateItemGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.id)), ["1", "2"])
        XCTAssertEqual(groups[0].map(\.title), ["a-copy.txt", "a.txt"], "sorted by title")
        // Removing one copy resolves the group.
        vm.deleteItem("2")
        XCTAssertTrue(vm.duplicateItemGroups.isEmpty, "one copy left ⇒ no duplicates")
        XCTAssertFalse(vm.items.contains { $0.id == "2" })
    }

    func testUntaggedCount() throws {
        let vm = try vmWithItems()   // items a,b,c,d
        vm.tagsByItem = ["a": ["work"], "b": [], "c": ["x", "y"]]   // d absent ⇒ untagged
        XCTAssertEqual(vm.untaggedCount, 2, "b (empty) and d (absent) are untagged")
        vm.tagsByItem["b"] = ["now"]
        XCTAssertEqual(vm.untaggedCount, 1)
    }

    func testRelatedTagsByCoOccurrence() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Rel-\(UUID().uuidString)")
        let vm = LibraryViewModel(store: try KnowledgeStore(directory: dir))
        // research co-occurs with ml twice and with vision once; finance is unrelated.
        vm.tagsByItem = [
            "1": ["research", "ml"],
            "2": ["research", "ml"],
            "3": ["research", "vision"],
            "4": ["finance"]
        ]
        let related = vm.relatedTags(to: "research")
        XCTAssertEqual(related.first, "ml", "strongest co-occurrence first")
        XCTAssertTrue(related.contains("vision"))
        XCTAssertFalse(related.contains("finance"), "unrelated label excluded")
        XCTAssertFalse(related.contains("research"), "the tag itself is not 'related' to itself")
        XCTAssertTrue(vm.relatedTags(to: "finance").isEmpty, "a label with no co-occurrences has no related tags")
    }

    func testSelectedTitlesOldestFirstForDiff() throws {
        let vm = try vmWithItems()
        // Select gamma (2 days old) and alpha (1 day old) — oldest should come first.
        vm.selection = ["a", "c"]
        XCTAssertEqual(vm.selectedTitlesOldestFirst(), ["gamma.pdf", "alpha.pdf"],
                       "older file (gamma, 2d) leads so a diff reads old → new")
        vm.selection = ["d"]
        XCTAssertEqual(vm.selectedTitlesOldestFirst(), ["delta.png"], "single selection still returns its title")
    }

    func testQueryAndFilterCombine() throws {
        let vm = try vmWithItems()
        vm.toggleKind(.pdf)
        vm.query = "gamma"
        XCTAssertEqual(vm.filtered.map(\.id), ["c"])
    }

    func testExportMarkdownIncludesContentAndCitations() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Exp-\(UUID().uuidString)")
        let store = try! KnowledgeStore(directory: dir)
        let vm = ChatViewModel(makeRAG: { fatalError("unused") },
                               makeTool: { fatalError("unused") },
                               store: store, settings: SettingsStore(defaults: UserDefaults(suiteName: "exp-\(UUID())")!))
        vm.messages = [
            ChatMessage(role: .user, content: "What about vectors?"),
            ChatMessage(role: .assistant, content: "They power search [1].",
                        citations: [Citation(index: 1, title: "notes.md", path: "/tmp/notes.md", snippet: "…")])
        ]
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.contains("### You"))
        XCTAssertTrue(md.contains("What about vectors?"))
        XCTAssertTrue(md.contains("### Mnemosyne"))
        XCTAssertTrue(md.contains("They power search [1]."))
        XCTAssertTrue(md.contains("[1] notes.md — … `/tmp/notes.md`"))
    }
}
