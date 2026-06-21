import XCTest
@testable import Mnemosyne

final class EmbeddedJSONTests: XCTestCase {

    func testExtractsObjectFromSurroundingProse() {
        let text = "Here is the data: {\"a\":1,\"b\":[2,3]} and that's it."
        XCTAssertEqual(EmbeddedJSON.first(text), "{\"a\":1,\"b\":[2,3]}")
    }

    func testExtractsArrayAndMultipleBlocks() {
        XCTAssertEqual(EmbeddedJSON.first("log: [1,2,3] done"), "[1,2,3]")
        let two = EmbeddedJSON.candidates("first {\"x\":1} then {\"y\":2} end")
        XCTAssertEqual(two, ["{\"x\":1}", "{\"y\":2}"])
    }

    func testIgnoresBracesInsideStrings() {
        // The "}" inside the string value must not end the object early.
        XCTAssertEqual(EmbeddedJSON.first("x = {\"s\":\"a}b\"} ;"), "{\"s\":\"a}b\"}")
    }

    func testRejectsInvalidJsonAndEmpty() {
        XCTAssertTrue(EmbeddedJSON.candidates("just text {not json} here").isEmpty)
        XCTAssertNil(EmbeddedJSON.first("no braces at all"))
        XCTAssertTrue(EmbeddedJSON.candidates("").isEmpty)
    }
}
