import XCTest
@testable import Mnemosyne

final class AsciiChartTests: XCTestCase {

    func testParsesCommaAndNewlinePairs() {
        let a = AsciiChart.parse("Jan: 8, Feb: 5, Mar: 3")
        XCTAssertEqual(a.map(\.label), ["Jan", "Feb", "Mar"])
        XCTAssertEqual(a.map(\.value), [8, 5, 3])

        let b = AsciiChart.parse("Q1: 1200\nQ2: 900")   // newline-separated pairs
        XCTAssertEqual(b.map(\.value), [1200, 900])
    }

    func testBarsScaleToWidthAndAlignLabels() {
        let chart = AsciiChart.bars([("Jan", 8), ("Feb", 4)], width: 8)
        let lines = chart.components(separatedBy: "\n")
        // Max value (8) fills the full width of 8 blocks; 4 → half.
        XCTAssertEqual(lines[0].filter { $0 == "█" }.count, 8)
        XCTAssertEqual(lines[1].filter { $0 == "█" }.count, 4)
        XCTAssertTrue(lines[0].hasSuffix(" 8"), lines[0])
    }

    func testRenderValueFormattingAndEmptyIsNil() {
        XCTAssertNil(AsciiChart.render("no pairs here"))
        XCTAssertNil(AsciiChart.render(""))
        let chart = AsciiChart.render("A: 2.5, B: 5", width: 10)
        XCTAssertNotNil(chart)
        XCTAssertTrue(chart!.contains(" 2.5"), chart ?? "")   // decimals preserved
        XCTAssertTrue(chart!.contains(" 5"), chart ?? "")     // whole shown as int
    }

    func testZeroValuesProduceNoBars() {
        let chart = AsciiChart.bars([("X", 0), ("Y", 0)], width: 10)
        XCTAssertFalse(chart.contains("█"), chart)
    }
}
