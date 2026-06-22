import XCTest
@testable import Mnemosyne

final class JSONExtractTests: XCTestCase {

    func testFencedJSONBlock() {
        let resp = "Here you go:\n```json\n{\"a\": 1, \"b\": [2, 3]}\n```\nHope that helps."
        XCTAssertEqual(JSONExtract.extract(from: resp), "{\"a\": 1, \"b\": [2, 3]}")
    }

    func testBareObject() {
        XCTAssertEqual(JSONExtract.extract(from: "  {\"x\": true}  "), "{\"x\": true}")
    }

    func testProseWrappingArray() {
        let resp = "The list is [1, 2, 3] as requested."
        XCTAssertEqual(JSONExtract.extract(from: resp), "[1, 2, 3]")
    }

    func testFenceWithoutLanguageTag() {
        XCTAssertEqual(JSONExtract.extract(from: "```\n{\"k\":\"v\"}\n```"), "{\"k\":\"v\"}")
    }

    func testNoJSONReturnsNil() {
        XCTAssertNil(JSONExtract.extract(from: "just some prose with no json"))
    }

    func testExtractValidRejectsBrokenJSON() {
        XCTAssertNil(JSONExtract.extractValid(from: "{not: valid, json"))
        XCTAssertEqual(JSONExtract.extractValid(from: "```json\n{\"ok\": 1}\n```"), "{\"ok\": 1}")
        XCTAssertTrue(JSONExtract.isValid("[1,2,3]"))
        XCTAssertFalse(JSONExtract.isValid("{oops}"))
    }
}
