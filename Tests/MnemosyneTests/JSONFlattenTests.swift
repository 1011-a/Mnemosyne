import XCTest
@testable import Mnemosyne

final class JSONFlattenTests: XCTestCase {

    func testFlattensNestedObjects() {
        let json = #"{"a":{"b":1},"c":2}"#
        let flat = JSONFlatten.flatten(json)
        XCTAssertEqual(flat?.map(\.path), ["a.b", "c"])
        XCTAssertEqual(flat?.map(\.value), ["1", "2"])
    }

    func testFlattensArraysWithIndexes() {
        let json = #"{"x":[10,20],"y":true}"#
        let flat = JSONFlatten.flatten(json)
        let dict = Dictionary(flat!.map { ($0.path, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["x[0]"], "10")
        XCTAssertEqual(dict["x[1]"], "20")
        XCTAssertEqual(dict["y"], "true")
    }

    func testDeepNesting() {
        let flat = JSONFlatten.flatten(#"{"a":{"b":{"c":[{"d":5}]}}}"#)
        XCTAssertEqual(flat?.first?.path, "a.b.c[0].d")
        XCTAssertEqual(flat?.first?.value, "5")
    }

    func testInvalidIsNil() {
        XCTAssertNil(JSONFlatten.flatten("not json"))
        XCTAssertNil(JSONFlatten.flatten(""))
    }
}
