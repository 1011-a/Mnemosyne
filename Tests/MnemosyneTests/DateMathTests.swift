import XCTest
@testable import Mnemosyne

final class DateMathTests: XCTestCase {

    func testDaysBetweenBasicAndSigned() {
        XCTAssertEqual(DateMath.daysBetween(from: "2026-01-01", to: "2026-01-08"), 7)
        XCTAssertEqual(DateMath.daysBetween(from: "2026-01-08", to: "2026-01-01"), -7)
        XCTAssertEqual(DateMath.daysBetween(from: "2026-06-15", to: "2026-06-15"), 0)
    }

    func testCrossesMonthAndYearBoundaries() {
        XCTAssertEqual(DateMath.daysBetween(from: "2026-02-28", to: "2026-03-01"), 1)   // 2026 not a leap year
        XCTAssertEqual(DateMath.daysBetween(from: "2025-12-31", to: "2026-01-01"), 1)
    }

    func testAcceptsSlashFormatAndRejectsJunk() {
        XCTAssertEqual(DateMath.daysBetween(from: "2026/01/01", to: "2026/01/03"), 2)
        XCTAssertNil(DateMath.daysBetween(from: "not a date", to: "2026-01-01"))
        XCTAssertNil(DateMath.parse("2026-13-40"))   // invalid month/day
    }

    func testPhraseWording() {
        XCTAssertTrue(DateMath.phrase(7, from: "2026-01-01", to: "2026-01-08").contains("7 days after"))
        XCTAssertTrue(DateMath.phrase(-3, from: "2026-01-08", to: "2026-01-05").contains("3 days before"))
        XCTAssertTrue(DateMath.phrase(1, from: "a", to: "b").contains("1 day after"))   // singular
        XCTAssertTrue(DateMath.phrase(0, from: "x", to: "x").contains("same day"))
    }
}
