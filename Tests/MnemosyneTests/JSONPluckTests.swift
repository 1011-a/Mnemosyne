import XCTest
@testable import Mnemosyne

final class JSONPluckTests: XCTestCase {

    func testPlucksFieldFromEachObject() {
        let json = #"[{"id":1,"name":"a"},{"id":2,"name":"b"}]"#
        XCTAssertEqual(JSONPluck.pluck(json, key: "id"), ["1", "2"])
        XCTAssertEqual(JSONPluck.pluck(json, key: "name"), ["a", "b"])
    }

    func testSkipsObjectsMissingTheKey() {
        let json = #"[{"id":1},{"name":"x"},{"id":3}]"#
        XCTAssertEqual(JSONPluck.pluck(json, key: "id"), ["1", "3"])
    }

    func testNonArrayIsNilAndUnknownKeyIsEmpty() {
        XCTAssertNil(JSONPluck.pluck(#"{"id":1}"#, key: "id"))   // object, not array
        XCTAssertNil(JSONPluck.pluck("not json", key: "id"))
        XCTAssertEqual(JSONPluck.pluck(#"[{"a":1}]"#, key: "b"), [])
    }

    func testRendersBooleanAndNestedValues() {
        let json = #"[{"ok":true,"tags":["x","y"]}]"#
        XCTAssertEqual(JSONPluck.pluck(json, key: "ok"), ["true"])
        XCTAssertEqual(JSONPluck.pluck(json, key: "tags"), [#"["x","y"]"#])
    }
}
