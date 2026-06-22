import XCTest
@testable import Mnemosyne

final class DeepSeekReasoningTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testExtractsReasoningContent() {
        let body = data("""
        {"choices":[{"message":{"role":"assistant","content":"42","reasoning_content":"Let me add the numbers.\\nThe sum is 42."}}]}
        """)
        XCTAssertEqual(DeepSeekReasoning.extract(from: body), "Let me add the numbers.\nThe sum is 42.")
    }

    func testAbsentOrEmptyReasoningIsNil() {
        // deepseek-chat: no reasoning_content field at all.
        XCTAssertNil(DeepSeekReasoning.extract(from: data(#"{"choices":[{"message":{"content":"hi"}}]}"#)))
        // present but blank.
        XCTAssertNil(DeepSeekReasoning.extract(from: data(#"{"choices":[{"message":{"reasoning_content":"   "}}]}"#)))
    }

    func testMalformedOrEmptyBodyIsNil() {
        XCTAssertNil(DeepSeekReasoning.extract(from: data("not json")))
        XCTAssertNil(DeepSeekReasoning.extract(from: data(#"{"choices":[]}"#)))
        XCTAssertNil(DeepSeekReasoning.extract(from: Data()))
    }

    func testSnippetTakesFirstLineAndTruncates() {
        XCTAssertEqual(DeepSeekReasoning.snippet("First thought\nsecond"), "First thought")
        let long = String(repeating: "a", count: 200)
        let snip = DeepSeekReasoning.snippet(long, max: 10)
        XCTAssertEqual(snip, "aaaaaaaaaa…")
    }

    func testSnippetCollapsesWhitespaceAndSkipsBlankLines() {
        XCTAssertEqual(DeepSeekReasoning.snippet("\n\n  hello   world  \n"), "hello world")
        XCTAssertNil(DeepSeekReasoning.snippet("   \n  "))
    }
}
