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

    func testParseAcrossFormats() {
        // All four of these denote the same calendar day.
        let iso = DateExtractor.parse("2026-01-05")
        XCTAssertNotNil(iso)
        XCTAssertEqual(DateExtractor.parse("1/5/2026"), iso, "US M/D/Y matches the ISO date")
        XCTAssertEqual(DateExtractor.parse("Jan 5, 2026"), iso)
        XCTAssertEqual(DateExtractor.parse("5th January 2026"), iso, "ordinal suffix tolerated")
        XCTAssertNil(DateExtractor.parse("not a date"))
    }

    func testChronologicalSortsEarliestFirst() {
        let text = "Kickoff Mar 1, 2026, due 2026-01-15, review 12/31/2025, ship 5 February 2026."
        let order = DateExtractor.chronological(text)
        XCTAssertEqual(order, ["12/31/2025", "2026-01-15", "5 February 2026", "Mar 1, 2026"],
                       "earliest → latest regardless of document order (Feb 5 precedes Mar 1)")
    }

    func testChronologicalAppendsUnparseableLast() {
        // 13/40/2026 matches the slashed shape but isn't a real date ⇒ kept, sorted last.
        let text = "Real 2026-02-02 and odd 13/40/2026."
        let order = DateExtractor.chronological(text)
        XCTAssertEqual(order.first, "2026-02-02", "parseable date leads")
        XCTAssertEqual(order.last, "13/40/2026", "unparseable recognized string trails")
    }
}
