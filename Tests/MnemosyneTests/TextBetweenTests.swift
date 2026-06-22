import XCTest
@testable import Mnemosyne

final class TextBetweenTests: XCTestCase {

    func testExtractsMultipleSpans() {
        XCTAssertEqual(TextBetween.extract("a[one]b[two]c", start: "[", end: "]"), ["one", "two"])
    }

    func testWorksWithMultiCharMarkers() {
        XCTAssertEqual(TextBetween.extract("<b>bold</b> and <b>more</b>", start: "<b>", end: "</b>"),
                       ["bold", "more"])
    }

    func testNonOverlappingAndUnmatched() {
        // After consuming the first pair, scanning resumes past the end marker.
        XCTAssertEqual(TextBetween.extract("[a][b]", start: "[", end: "]"), ["a", "b"])
        XCTAssertTrue(TextBetween.extract("start but no end", start: "[", end: "]").isEmpty)
    }

    func testEmptyMarkersAndSummaryNil() {
        XCTAssertTrue(TextBetween.extract("text", start: "", end: "]").isEmpty)
        XCTAssertNil(TextBetween.summary("nothing here", start: "[", end: "]"))
        let s = TextBetween.summary("x[hit]y", start: "[", end: "]")
        XCTAssertTrue(s?.contains("• hit") ?? false, s ?? "")
    }
}
