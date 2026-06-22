import XCTest
@testable import Mnemosyne

final class TallyTests: XCTestCase {

    func testCountsAndSortsByFrequency() {
        let c = Tally.count("open\nopen\nclosed\nopen\nclosed")
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].value, "open")
        XCTAssertEqual(c[0].count, 3)
        XCTAssertEqual(c[1].value, "closed")
        XCTAssertEqual(c[1].count, 2)
    }

    func testTieBrokenAlphabetically() {
        let c = Tally.count("banana, apple, cherry")   // all count 1
        XCTAssertEqual(c.map(\.value), ["apple", "banana", "cherry"])
    }

    func testTrimsAndSkipsBlanks() {
        let c = Tally.count("  a \n\n a \n b ")
        XCTAssertEqual(c.first?.value, "a")
        XCTAssertEqual(c.first?.count, 2)
        XCTAssertEqual(c.count, 2)
    }

    func testSummaryFormatAndEmptyIsNil() {
        let s = Tally.summary("x\nx\ny")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("3 item(s), 2 unique"), s ?? "")
        XCTAssertTrue(s!.contains("x: 2"), s ?? "")
        XCTAssertNil(Tally.summary("   \n  "))
        XCTAssertNil(Tally.summary(""))
    }
}
