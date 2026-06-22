import XCTest
@testable import Mnemosyne

final class JSONModeTests: XCTestCase {

    func testBodySetsResponseFormat() {
        let body = JSONMode.body(prior: [["role": "user", "content": "give me json"]],
                                 model: "deepseek-chat")
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        let rf = body["response_format"] as? [String: Any]
        XCTAssertEqual(rf?["type"] as? String, "json_object")
    }

    func testHintAddedWhenJSONNotMentioned() {
        let prior: [[String: Any]] = [["role": "user", "content": "Summarize this."]]
        let withHint = JSONMode.ensureJSONHint(prior)
        XCTAssertEqual(withHint.count, 2)
        XCTAssertEqual(withHint.first?["role"] as? String, "system")
        XCTAssertTrue((withHint.first?["content"] as? String ?? "").lowercased().contains("json"))
    }

    func testHintNotDuplicatedWhenJSONPresent() {
        let prior: [[String: Any]] = [["role": "user", "content": "Return JSON please."]]
        XCTAssertEqual(JSONMode.ensureJSONHint(prior).count, 1)   // unchanged
    }

    func testBodyMessagesCountReflectsHint() {
        let body = JSONMode.body(prior: [["role": "user", "content": "no mention"]], model: "m")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 2)   // hint prepended
    }
}
