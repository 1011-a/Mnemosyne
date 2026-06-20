import XCTest
@testable import Mnemosyne

final class CopyableTextTests: XCTestCase {

    func testIncludesAnswerAndSourcesWithSnippets() {
        let msg = ChatMessage(role: .assistant, content: "FAISS is fast [1].",
                              citations: [
                                Citation(index: 1, title: "faiss.pdf", path: "/p/faiss.pdf",
                                         snippet: "FAISS provides   efficient search."),
                                Citation(index: 2, title: "notes.md", path: "/p/notes.md", snippet: ""),
                              ])
        let text = msg.copyableText
        XCTAssertTrue(text.contains("FAISS is fast [1]."))
        XCTAssertTrue(text.contains("Sources:"))
        XCTAssertTrue(text.contains("[1] faiss.pdf — FAISS provides efficient search."))
        XCTAssertTrue(text.contains("[2] notes.md"))               // snippet-less still listed
        XCTAssertFalse(text.contains("[2] notes.md — "))           // no trailing dash when empty
    }

    func testNoCitationsIsJustTheAnswer() {
        let msg = ChatMessage(role: .assistant, content: "Plain answer.")
        XCTAssertEqual(msg.copyableText, "Plain answer.")
    }
}
