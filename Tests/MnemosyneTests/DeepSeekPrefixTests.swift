import XCTest
@testable import Mnemosyne

final class DeepSeekPrefixTests: XCTestCase {

    func testBetaBaseURLDerivation() {
        XCTAssertEqual(DeepSeekPrefix.betaBaseURL(URL(string: "https://api.deepseek.com")!).absoluteString,
                       "https://api.deepseek.com/beta")
        XCTAssertEqual(DeepSeekPrefix.betaBaseURL(URL(string: "https://api.deepseek.com/v1")!).absoluteString,
                       "https://api.deepseek.com/beta")
        XCTAssertEqual(DeepSeekPrefix.betaBaseURL(URL(string: "https://api.deepseek.com/beta")!).absoluteString,
                       "https://api.deepseek.com/beta")
    }

    func testPrefixMessageAppendedLastWithFlag() {
        let prior: [[String: Any]] = [["role": "user", "content": "Give me JSON."]]
        let msgs = DeepSeekPrefix.messages(prior, prefix: "```json\n")
        XCTAssertEqual(msgs.count, 2)
        let last = msgs.last!
        XCTAssertEqual(last["role"] as? String, "assistant")
        XCTAssertEqual(last["content"] as? String, "```json\n")
        XCTAssertEqual(last["prefix"] as? Bool, true)
    }

    func testBodyIncludesStopWhenProvided() {
        let body = DeepSeekPrefix.body(prior: [["role": "user", "content": "x"]],
                                       prefix: "```json\n", model: "deepseek-chat", stop: ["```"])
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertEqual(body["stop"] as? [String], ["```"])
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 2)
    }

    func testBodyOmitsStopWhenEmpty() {
        let body = DeepSeekPrefix.body(prior: [], prefix: "Answer:", model: "deepseek-chat")
        XCTAssertNil(body["stop"])
        // even with no prior messages, the assistant prefix is present.
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
    }
}
