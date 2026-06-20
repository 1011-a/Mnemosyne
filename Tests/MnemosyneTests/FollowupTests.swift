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
}
