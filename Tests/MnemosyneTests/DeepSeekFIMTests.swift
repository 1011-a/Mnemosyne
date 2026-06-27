import XCTest
@testable import Mnemosyne

final class DeepSeekFIMTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testBodyHasPromptSuffixAndMaxTokens() {
        let body = DeepSeekFIM.body(prompt: "def add(a, b):\n    return ",
                                    suffix: "\n\nprint(add(1, 2))",
                                    model: "deepseek-v4-flash", maxTokens: 64)
        XCTAssertEqual(body["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(body["prompt"] as? String, "def add(a, b):\n    return ")
        XCTAssertEqual(body["suffix"] as? String, "\n\nprint(add(1, 2))")
        XCTAssertEqual(body["max_tokens"] as? Int, 64)
    }

    func testEmptySuffixAndNonPositiveMaxAreOmitted() {
        let body = DeepSeekFIM.body(prompt: "x", suffix: "", model: "deepseek-v4-flash", maxTokens: 0)
        XCTAssertNil(body["suffix"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["prompt"] as? String, "x")
    }

    func testExtractTextFromCompletionResponse() {
        let body = data(#"{"choices":[{"text":"a + b","index":0}]}"#)
        XCTAssertEqual(DeepSeekFIM.extractText(from: body), "a + b")
    }

    func testExtractTextNilOnMalformedOrEmpty() {
        XCTAssertNil(DeepSeekFIM.extractText(from: data(#"{"choices":[]}"#)))
        XCTAssertNil(DeepSeekFIM.extractText(from: data("not json")))
        XCTAssertNil(DeepSeekFIM.extractText(from: Data()))
    }
}
