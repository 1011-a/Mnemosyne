import XCTest
@testable import Mnemosyne

final class FollowupTests: XCTestCase {

    func testDisplayTitleStripsExtensionAndSeparators() {
        XCTAssertEqual(FollowupSuggester.displayTitle("vector-db-notes.md"), "vector db notes")
        XCTAssertEqual(FollowupSuggester.displayTitle("faiss.pdf"), "faiss")
        XCTAssertEqual(FollowupSuggester.displayTitle("My_Report"), "My Report")
        XCTAssertEqual(FollowupSuggester.displayTitle("no.extension.here"), "no.extension")
    }

    func testSourceGroundedFollowupsFirst() {
        let cites = [
            Citation(index: 1, title: "faiss.pdf", path: "/p", snippet: "", itemID: "a"),
            Citation(index: 2, title: "vector-db-notes.md", path: "/p", snippet: "", itemID: "b")
        ]
        let s = FollowupSuggester.suggest(question: "vectors?", citations: cites)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0], "Tell me more about faiss")
        XCTAssertEqual(s[1], "Tell me more about vector db notes")
        XCTAssertEqual(s[2], "What are the key takeaways?")
    }

    func testGenericsWhenNoCitations() {
        let s = FollowupSuggester.suggest(question: "anything", citations: [])
        XCTAssertEqual(s, ["What are the key takeaways?", "How does this relate to my other files?"])
    }

    func testDedupesRepeatedSources() {
        let cites = [
            Citation(index: 1, title: "faiss.pdf", path: "/p", snippet: "", itemID: "a"),
            Citation(index: 2, title: "faiss.pdf", path: "/p2", snippet: "", itemID: "a")
        ]
        let s = FollowupSuggester.suggest(question: "q", citations: cites)
        XCTAssertEqual(s.filter { $0 == "Tell me more about faiss" }.count, 1)
    }

    // MARK: action-oriented follow-ups

    private let longAnswer = String(repeating: "Vector search uses embeddings to rank results. ", count: 8)

    func testActionFollowupsAreGroundedAndActionable() {
        let cites = [
            Citation(index: 1, title: "faiss.pdf", path: "/p", snippet: "", itemID: "a"),
            Citation(index: 2, title: "vector-db-notes.md", path: "/p", snippet: "", itemID: "b")
        ]
        let f = FollowupSuggester.followups(question: "How does vector search work?",
                                            answer: longAnswer, citations: cites)
        XCTAssertLessThanOrEqual(f.count, 4)
        // A substantial, grounded answer offers a build action and a compare action.
        XCTAssertTrue(f.contains { $0.isAction && $0.send.hasPrefix("Create a one-page HTML") }, "should offer to build")
        XCTAssertTrue(f.contains { $0.send.hasPrefix("Compare faiss and vector db notes") }, "two sources ⇒ compare")
        XCTAssertTrue(f.allSatisfy { !$0.label.isEmpty && !$0.send.isEmpty && !$0.icon.isEmpty })
    }

    func testCompareSuppressedWithOneSource() {
        let cites = [Citation(index: 1, title: "faiss.pdf", path: "/p", snippet: "", itemID: "a")]
        let f = FollowupSuggester.followups(question: "vectors?", answer: longAnswer, citations: cites)
        XCTAssertFalse(f.contains { $0.send.lowercased().hasPrefix("compare") }, "one source ⇒ no compare action")
    }

    func testThinAnswerSuppressesBuildAndSave() {
        let cites = [Citation(index: 1, title: "faiss.pdf", path: "/p", snippet: "", itemID: "a")]
        let f = FollowupSuggester.followups(question: "what is faiss?", answer: "A library.", citations: cites)
        XCTAssertFalse(f.contains { $0.send.hasPrefix("Create a one-page HTML") }, "thin answer ⇒ no build")
        XCTAssertFalse(f.contains { $0.send.hasPrefix("Save a note") }, "thin answer ⇒ no save")
        // The web escape-hatch is always available.
        XCTAssertTrue(f.contains { $0.send.hasPrefix("Search the web for") })
    }

    func testTopicPhraseTrimsPunctuationAndLength() {
        XCTAssertEqual(FollowupSuggester.topicPhrase("How does vector search work?"), "How does vector search work")
        XCTAssertEqual(FollowupSuggester.topicPhrase("摘要？"), "摘要")
        XCTAssertEqual(FollowupSuggester.topicPhrase("   "), "this topic")
        XCTAssertTrue(FollowupSuggester.topicPhrase(String(repeating: "x", count: 200)).hasSuffix("…"))
    }
}
