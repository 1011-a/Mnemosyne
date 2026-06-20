import XCTest
@testable import Mnemosyne

/// Real UI testing: drives the actual view-model actions that the buttons and
/// controls invoke and asserts on the resulting state — deterministic, offline,
/// and run every iteration. (Accessibility identifiers are attached to the
/// controls in the views so an XCUITest target can drive them too, but the
/// SwiftPM executable can't host XCUITest, and AppleScript/AX traversal of this
/// SwiftUI app is intermittent — so behavior is asserted at the view-model layer.)
@MainActor
final class UIBehaviorTests: XCTestCase {

    // MARK: fixtures

    private func tempStore() throws -> KnowledgeStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try KnowledgeStore(directory: dir)
    }

    private func makeChat() throws -> ChatViewModel {
        ChatViewModel(makeRAG: { fatalError("agent unused in this test") },
                      makeTool: { fatalError("agent unused in this test") },
                      store: try tempStore(), settings: TestSupport.settings())
    }

    private func item(_ id: String, _ title: String, kind: ItemKind = .text,
                      summary: String = "", size: Int64 = 100,
                      modified: Date = Date()) -> KnowledgeItem {
        KnowledgeItem(id: id, path: "/tmp/\(id)", title: title, kind: kind,
                      contentHash: id, byteSize: size,
                      createdAt: Date(), modifiedAt: modified, summary: summary)
    }

    // MARK: Chat — top-bar buttons (New Chat, Export) and thread switching

    func testNewChatButtonClearsConversation() throws {
        let vm = try makeChat()
        vm.messages = [ChatMessage(role: .user, content: "hi"),
                       ChatMessage(role: .assistant, content: "hello")]
        vm.isStreaming = true
        let oldID = vm.threadID
        vm.newThread()                          // ← what the "New Chat" button calls
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.title, "New chat")
        XCTAssertNotEqual(vm.threadID, oldID)
    }

    func testExportButtonProducesMarkdownWithSources() throws {
        let vm = try makeChat()
        vm.messages = [
            ChatMessage(role: .user, content: "What is FAISS?"),
            ChatMessage(role: .assistant, content: "A similarity-search library.",
                        citations: [Citation(index: 1, title: "faiss.pdf",
                                             path: "/p/faiss.pdf",
                                             snippet: "A similarity-search library.", itemID: "i1")])
        ]
        let md = vm.exportMarkdown()            // ← what the "Export" button serializes
        XCTAssertTrue(md.contains("### You"))
        XCTAssertTrue(md.contains("What is FAISS?"))
        XCTAssertTrue(md.contains("### Mnemosyne"))
        XCTAssertTrue(md.contains("**Sources**"))
        // Export carries title, snippet provenance, and path.
        XCTAssertTrue(md.contains("- [1] faiss.pdf — A similarity-search library. `/p/faiss.pdf`"))
    }

    func testHistoryRowOpensThreadIdentity() throws {
        let vm = try makeChat()
        let thread = ChatThread(id: "T1", title: "My Thread")
        vm.open(thread)                         // ← what a history-popover row calls
        XCTAssertEqual(vm.threadID, "T1")
        XCTAssertEqual(vm.title, "My Thread")
    }

    // MARK: Library — filter chips, search field, tag chips, Select, sort

    func testKindFilterChipTogglesAndCountsAreCorrect() throws {
        let vm = LibraryViewModel(store: try tempStore())
        vm.items = [item("a", "A", kind: .image), item("b", "B", kind: .image),
                    item("c", "C", kind: .pdf)]
        // The numbers shown on the filter chips:
        let counts = Dictionary(uniqueKeysWithValues: vm.kindCounts.map { ($0.kind, $0.count) })
        XCTAssertEqual(counts[.image], 2)
        XCTAssertEqual(counts[.pdf], 1)
        // Tapping the "image" chip filters to images only:
        vm.toggleKind(.image)
        XCTAssertEqual(vm.filtered.count, 2)
        XCTAssertTrue(vm.filtered.allSatisfy { $0.kind == .image })
        // Tapping again clears the filter:
        vm.toggleKind(.image)
        XCTAssertEqual(vm.filtered.count, 3)
    }

    func testSearchFieldMatchesTitleAndSummary() throws {
        let vm = LibraryViewModel(store: try tempStore())
        vm.items = [item("a", "Budget Report", summary: "quarterly cloud spend"),
                    item("b", "cat.png", kind: .image)]
        vm.query = "budget"                     // title match
        XCTAssertEqual(vm.filtered.map(\.id), ["a"])
        vm.query = "quarterly"                  // summary match
        XCTAssertEqual(vm.filtered.map(\.id), ["a"])
        vm.query = "nonexistent"
        XCTAssertTrue(vm.filtered.isEmpty)
    }

    func testTagChipFilters() throws {
        let vm = LibraryViewModel(store: try tempStore())
        vm.items = [item("a", "A"), item("b", "B")]
        vm.tagsByItem = ["a": ["work"], "b": ["home"]]
        XCTAssertEqual(vm.tagCounts.map(\.tag).sorted(), ["home", "work"])
        vm.activeTag = "work"
        XCTAssertEqual(vm.filtered.map(\.id), ["a"])
    }

    func testSelectButtonAndSelectAll() throws {
        let vm = LibraryViewModel(store: try tempStore())
        vm.items = [item("a", "A"), item("b", "B"), item("c", "C")]
        vm.toggleSelectionMode()                // ← "Select" button
        XCTAssertTrue(vm.selectionMode)
        vm.selectAllFiltered()
        XCTAssertEqual(vm.selection.count, 3)
        vm.toggleSelected("a")                  // deselect one
        XCTAssertEqual(vm.selection.count, 2)
        vm.toggleSelectionMode()                // exiting select mode clears selection
        XCTAssertFalse(vm.selectionMode)
        XCTAssertTrue(vm.selection.isEmpty)
    }

    func testClearFiltersResetsSearchKindsAndTag() throws {
        let vm = LibraryViewModel(store: try tempStore())
        vm.items = [item("a", "A", kind: .image), item("b", "B", kind: .pdf)]
        vm.query = "report"
        vm.toggleKind(.image)
        vm.activeTag = "work"
        vm.contentMatchIDs = ["a"]
        XCTAssertTrue(vm.hasActiveFilter)
        vm.clearFilters()                     // ← what Esc invokes
        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.activeKinds.isEmpty)
        XCTAssertNil(vm.activeTag)
        XCTAssertTrue(vm.contentMatchIDs.isEmpty)
        XCTAssertFalse(vm.hasActiveFilter)
        XCTAssertEqual(vm.filtered.count, 2)  // all items visible again
    }

    func testSortControlOrdersByName() throws {
        let vm = LibraryViewModel(store: try tempStore())
        vm.items = [item("a", "Zebra"), item("b", "apple"), item("c", "Mango")]
        vm.sort = .name                         // ← the "Recent ▾" sort menu
        XCTAssertEqual(vm.filtered.map(\.title), ["apple", "Mango", "Zebra"])
    }

    // MARK: Settings — toggles & sliders persist

    func testSettingsTogglesAndSlidersPersist() {
        let suite = "MnemoUITest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s1 = SettingsStore(defaults: defaults)
        s1.agentic = false                      // ← "Agentic mode" toggle
        s1.multimodal = true                    // ← "Use Gemma…" toggle
        s1.keywordWeight = 0.7                   // ← "Keyword vs. semantic" slider
        s1.topK = 12                            // ← "Sources retrieved" stepper
        // A fresh store on the same defaults must read back the persisted values.
        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.agentic, false)
        XCTAssertEqual(s2.multimodal, true)
        XCTAssertEqual(s2.keywordWeight, 0.7, accuracy: 0.001)
        XCTAssertEqual(s2.topK, 12)
        defaults.removePersistentDomain(forName: suite)
    }

    func testKeywordWeightSliderClampedToUnitRange() {
        let s = TestSupport.settings()
        s.keywordWeight = 1.8
        XCTAssertLessThanOrEqual(s.keywordWeight, 1.0)
        s.keywordWeight = -0.5
        XCTAssertGreaterThanOrEqual(s.keywordWeight, 0.0)
    }
}
