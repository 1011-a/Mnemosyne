import XCTest
@testable import Mnemosyne

final class PercentExtractorTests: XCTestCase {

    func testExtractsValuesIncludingDecimalsSpacesAndNegatives() {
        let vs = PercentExtractor.values("Up 45%, down -3%, margin 12.5 %.")
        XCTAssertEqual(vs.map(\.value), [45, -3, 12.5])
        XCTAssertEqual(vs.map(\.text), ["45%", "-3%", "12.5 %"])
    }

    func testKeepsAllOccurrencesNotDeduped() {
        XCTAssertEqual(PercentExtractor.values("10% and again 10%").count, 2)
    }

    func testSummaryReportsStats() {
        let s = PercentExtractor.summary("scores: 50%, 100%, 0%")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("3 percentage(s)"), s ?? "")
        XCTAssertTrue(s!.contains("avg 50%"), s ?? "")
        XCTAssertTrue(s!.contains("min 0%"), s ?? "")
        XCTAssertTrue(s!.contains("max 100%"), s ?? "")
    }

    func testNoneIsNil() {
        XCTAssertTrue(PercentExtractor.values("no percentages here").isEmpty)
        XCTAssertNil(PercentExtractor.summary("plain text"))
    }
}
