import XCTest
@testable import Mnemosyne

final class JsonTests: XCTestCase {

    func testFlattensNestedObjectWithSortedKeys() {
        let text = JsonExtractor.parse(Data(#"{"user":{"name":"Alice","age":30}}"#.utf8))
        XCTAssertEqual(text, "user.age: 30\nuser.name: Alice")
    }

    func testArrayIndices() {
        let text = JsonExtractor.parse(Data(#"{"tags":["swift","search"]}"#.utf8))
        XCTAssertEqual(text, "tags[0]: swift\ntags[1]: search")
    }

    func testBooleansAndNulls() {
        // null dropped; bool stays true/false (not 1/0); zero kept.
        let text = JsonExtractor.parse(Data(#"{"active":true,"count":0,"deleted":null}"#.utf8))
        XCTAssertEqual(text, "active: true\ncount: 0")
    }

    func testTopLevelArrayFragment() {
        XCTAssertEqual(JsonExtractor.parse(Data("[1,2,3]".utf8)), "[0]: 1\n[1]: 2\n[2]: 3")
    }

    func testInvalidJsonIsEmpty() {
        XCTAssertTrue(JsonExtractor.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(JsonExtractor.parse(Data()).isEmpty)
    }

    func testIsJsonAndKindMapping() {
        XCTAssertTrue(JsonExtractor.isJson(URL(fileURLWithPath: "/tmp/config.json")))
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/config.json")), .data)
    }
}
