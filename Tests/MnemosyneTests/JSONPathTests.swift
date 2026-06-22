import XCTest
@testable import Mnemosyne

final class JSONPathTests: XCTestCase {

    func testParsesKeysAndIndices() {
        XCTAssertEqual(JSONPath.parse("address.city"), [.key("address"), .key("city")])
        XCTAssertEqual(JSONPath.parse("items[0].id"), [.key("items"), .index(0), .key("id")])
        XCTAssertEqual(JSONPath.parse("[2]"), [.index(2)])
        XCTAssertNil(JSONPath.parse(""))
        XCTAssertNil(JSONPath.parse("a[x]"), "non-integer index is malformed")
        XCTAssertNil(JSONPath.parse("a[0"), "unbalanced bracket is malformed")
    }

    func testLookupWalksObjectsAndArrays() {
        let json = #"{"user":{"name":"Ada"},"items":[{"id":1},{"id":2}]}"#
        let root = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(JSONPath.lookup(root: root, path: JSONPath.parse("user.name")!) as? String, "Ada")
        XCTAssertEqual(JSONPath.lookup(root: root, path: JSONPath.parse("items[1].id")!) as? Int, 2)
        XCTAssertNil(JSONPath.lookup(root: root, path: JSONPath.parse("items[5]")!), "out of range")
        XCTAssertNil(JSONPath.lookup(root: root, path: JSONPath.parse("user.email")!), "missing key")
    }

    func testQueryOutcomes() {
        let json = #"{"active":true,"count":42,"tags":["x","y"]}"#
        XCTAssertEqual(JSONPath.query(json, path: "active"), .found("true"))   // boolean rendered
        XCTAssertEqual(JSONPath.query(json, path: "count"), .found("42"))
        XCTAssertEqual(JSONPath.query(json, path: "tags"), .found(#"["x","y"]"#))  // container as compact JSON
        XCTAssertEqual(JSONPath.query(json, path: "missing"), .notFound)
        XCTAssertEqual(JSONPath.query(json, path: "a[x]"), .badPath)
        XCTAssertEqual(JSONPath.query("not json {", path: "a"), .badJSON)
    }
}
