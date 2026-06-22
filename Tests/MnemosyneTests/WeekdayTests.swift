import XCTest
@testable import Mnemosyne

final class WeekdayTests: XCTestCase {

    func testKnownDates() {
        XCTAssertEqual(Weekday.of("2026-06-22"), "Monday")     // anchor
        XCTAssertEqual(Weekday.of("2000-01-01"), "Saturday")   // Y2K was a Saturday
        XCTAssertEqual(Weekday.of("2024-02-29"), "Thursday")   // leap day
        XCTAssertEqual(Weekday.of("1970-01-01"), "Thursday")   // Unix epoch
    }

    func testJanuaryFebruaryHandledByZeller() {
        XCTAssertEqual(Weekday.of("2026-01-01"), "Thursday")
        XCTAssertEqual(Weekday.of("2026-02-14"), "Saturday")
    }

    func testInvalidDatesReturnNil() {
        XCTAssertNil(Weekday.of("2023-02-29"))   // not a leap year
        XCTAssertNil(Weekday.of("2026-13-01"))   // bad month
        XCTAssertNil(Weekday.of("2026-06-31"))   // June has 30 days
        XCTAssertNil(Weekday.of("not-a-date"))
        XCTAssertNil(Weekday.of("2026/06/22"))   // wrong separator
    }
}
