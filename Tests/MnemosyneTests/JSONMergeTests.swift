import XCTest
@testable import Mnemosyne

final class JSONMergeTests: XCTestCase {

    private func obj(_ json: String) -> [String: Any]? {
        guard let d = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func testTopLevelMergeSecondWins() {
        let merged = JSONMerge.merge(#"{"a":1,"b":2}"#, #"{"b":3,"c":4}"#)
        let o = obj(merged!)
        XCTAssertEqual(o?["a"] as? Int, 1)
        XCTAssertEqual(o?["b"] as? Int, 3)   // b overwritten
        XCTAssertEqual(o?["c"] as? Int, 4)
    }

    func testDeepMergeCombinesNestedObjects() {
        let merged = JSONMerge.merge(#"{"x":{"p":1}}"#, #"{"x":{"q":2}}"#, deep: true)
        let x = obj(merged!)?["x"] as? [String: Any]
        XCTAssertEqual(x?["p"] as? Int, 1)
        XCTAssertEqual(x?["q"] as? Int, 2)
    }

    func testShallowMergeReplacesNestedObject() {
        let merged = JSONMerge.merge(#"{"x":{"p":1}}"#, #"{"x":{"q":2}}"#, deep: false)
        let x = obj(merged!)?["x"] as? [String: Any]
        XCTAssertNil(x?["p"])               // whole nested object replaced
        XCTAssertEqual(x?["q"] as? Int, 2)
    }

    func testNonObjectInputIsNil() {
        XCTAssertNil(JSONMerge.merge("[1,2]", #"{"a":1}"#))
        XCTAssertNil(JSONMerge.merge(#"{"a":1}"#, "not json"))
    }
}
