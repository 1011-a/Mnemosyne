import XCTest
@testable import Mnemosyne

final class ListFormatterTests: XCTestCase {

    func testNumberedAndBullet() {
        XCTAssertEqual(ListFormatter.format("a\nb\nc", style: "numbered"), "1. a\n2. b\n3. c")
        XCTAssertEqual(ListFormatter.format("a\nb", style: "bullet"), "- a\n- b")
    }

    func testCommaAndOxfordSentence() {
        XCTAssertEqual(ListFormatter.format("a\nb\nc", style: "comma"), "a, b, c")
        XCTAssertEqual(ListFormatter.format("a\nb\nc", style: "and"), "a, b, and c")
        XCTAssertEqual(ListFormatter.format("x\ny", style: "and"), "x and y")
        XCTAssertEqual(ListFormatter.format("solo", style: "and"), "solo")
    }

    func testStripsExistingMarkersBeforeReformatting() {
        XCTAssertEqual(ListFormatter.format("1. a\n2. b", style: "bullet"), "- a\n- b")
        XCTAssertEqual(ListFormatter.format("- a\n* b", style: "numbered"), "1. a\n2. b")
    }

    func testUnknownStyleAndEmptyAreNil() {
        XCTAssertNil(ListFormatter.format("a\nb", style: "table"))
        XCTAssertNil(ListFormatter.format("   \n  ", style: "bullet"))
    }
}
