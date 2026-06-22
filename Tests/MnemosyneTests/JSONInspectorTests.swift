import XCTest
@testable import Mnemosyne

final class JSONInspectorTests: XCTestCase {

    func testTopLevelObjectKeysAndTypesSortedWithBooleanDistinct() {
        let json = #"{"name":"Ada","age":36,"active":true,"tags":["x","y"]}"#
        let shape = JSONInspector.shape(json)
        XCTAssertNotNil(shape)
        let lines = shape!.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "object (4 keys)")
        // Keys sorted alphabetically: active, age, name, tags.
        XCTAssertEqual(lines[1], "  active: boolean")     // not "number"
        XCTAssertEqual(lines[2], "  age: number")
        XCTAssertEqual(lines[3], "  name: string")
        XCTAssertEqual(lines[4], "  tags: array[2] of string")
    }

    func testNestedObjectRecursesIndented() {
        let json = #"{"address":{"city":"London","zip":12345}}"#
        let shape = JSONInspector.shape(json)!
        XCTAssertTrue(shape.contains("address: object (2 keys)"), shape)
        XCTAssertTrue(shape.contains("    city: string"), shape)   // deeper indent
        XCTAssertTrue(shape.contains("    zip: number"), shape)
    }

    func testTopLevelArrayOfObjectsShowsRepresentativeElement() {
        let json = #"[{"id":1,"ok":false},{"id":2,"ok":true}]"#
        let shape = JSONInspector.shape(json)!
        let lines = shape.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "array[2] of object")
        XCTAssertTrue(shape.contains("id: number"), shape)
        XCTAssertTrue(shape.contains("ok: boolean"), shape)
    }

    func testInvalidJsonReturnsNil() {
        XCTAssertNil(JSONInspector.shape("not json {"))
        XCTAssertNil(JSONInspector.shape(""))
    }
}
