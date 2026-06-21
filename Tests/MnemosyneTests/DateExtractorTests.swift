import XCTest
@testable import Mnemosyne

final class DateExtractorTests: XCTestCase {

    func testIsoAndSlashedDates() {
        XCTAssertEqual(DateExtractor.extract("Due 2026-01-05 and again 12/31/2025."),
                       ["2026-01-05", "12/31/2025"])
    }

    func testMonthNameForms() {
        XCTAssertEqual(DateExtractor.extract("Meeting on Jan 5, 2026."), ["Jan 5, 2026"])
        XCTAssertEqual(DateExtractor.extract("Filed 5 January 2026 by counsel."), ["5 January 2026"])
        XCTAssertEqual(DateExtractor.extract("Deadline: 3rd Feb 2027."), ["3rd Feb 2027"])
    }

    func testDocumentOrderAndDedupe() {
        let text = "First 2026-03-01, then Mar 1, 2026, then again 2026-03-01 (repeat)."
        let dates = DateExtractor.extract(text)
        XCTAssertEqual(dates.first, "2026-03-01", "earliest position first")
        XCTAssertEqual(dates.filter { $0 == "2026-03-01" }.count, 1, "duplicate collapsed")
        XCTAssertTrue(dates.contains("Mar 1, 2026"))
    }

    func testNoDates() {
        XCTAssertTrue(DateExtractor.extract("There are no dates in this sentence at all.").isEmpty)
        XCTAssertTrue(DateExtractor.extract("").isEmpty)
    }
}
