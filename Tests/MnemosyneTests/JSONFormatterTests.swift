import XCTest
@testable import Mnemosyne

final class JSONFormatterTests: XCTestCase {

    func testPrettyIndentsAndSortsKeys() {
        let out = JSONFormatter.pretty(#"{"b":1,"a":2}"#)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("\n"), out ?? "")                       // indented
        XCTAssertTrue(out!.range(of: "\"a\"")!.lowerBound < out!.range(of: "\"b\"")!.lowerBound, out ?? "")  // sorted
    }

    func testMinifyRemovesWhitespace() {
        let out = JSONFormatter.minify("{\n  \"a\" : 1,\n  \"b\" : 2\n}")
        XCTAssertEqual(out, #"{"a":1,"b":2}"#)
    }

    func testEmptyContainersStayClean() {
        XCTAssertEqual(JSONFormatter.pretty("[]"), "[]")        // not "[\n\n]"
        XCTAssertEqual(JSONFormatter.pretty("{}"), "{}")
    }

    func testInvalidJsonIsNil() {
        XCTAssertNil(JSONFormatter.pretty("not json"))
        XCTAssertNil(JSONFormatter.minify("{unquoted: 1}"))
        XCTAssertNil(JSONFormatter.pretty("42"))               // bare scalar rejected (need object/array)
    }
}
