import XCTest
@testable import Mnemosyne

final class JSONKeysTests: XCTestCase {

    func testNestedObjectAndArrayOfObjects() {
        let json = #"{"user":{"name":"x"},"items":[{"id":1},{"id":2}]}"#
        XCTAssertEqual(JSONKeys.paths(json), ["items", "items[].id", "user", "user.name"])
    }

    func testUnionsKeysAcrossArrayElements() {
        let json = #"{"rows":[{"a":1},{"b":2}]}"#
        XCTAssertEqual(JSONKeys.paths(json), ["rows", "rows[].a", "rows[].b"])
    }

    func testTopLevelArray() {
        XCTAssertEqual(JSONKeys.paths(#"[{"id":1}]"#), ["[].id"])
    }

    func testInvalidIsNil() {
        XCTAssertNil(JSONKeys.paths("not json"))
        XCTAssertNil(JSONKeys.paths(""))
    }
}
