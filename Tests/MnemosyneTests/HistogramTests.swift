import XCTest
@testable import Mnemosyne

final class HistogramTests: XCTestCase {

    func testBinCountAndTotalPreserved() {
        let nums = (1...10).map(Double.init)
        let bins = Histogram.bins(nums, count: 5)
        XCTAssertEqual(bins?.count, 5)
        XCTAssertEqual(bins?.reduce(0) { $0 + $1.count }, 10)   // every value counted once
    }

    func testAllEqualSingleBin() {
        let bins = Histogram.bins([5, 5, 5], count: 4)
        XCTAssertEqual(bins?.count, 1)
        XCTAssertEqual(bins?.first?.count, 3)
    }

    func testEmptyAndZeroBins() {
        XCTAssertNil(Histogram.bins([], count: 5))
        XCTAssertNil(Histogram.bins([1, 2], count: 0))
    }

    func testChartHasABarPerBin() {
        let bins = Histogram.bins([1, 2, 3, 4], count: 2)!
        let chart = Histogram.chart(bins)
        XCTAssertEqual(chart.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(chart.contains("█"), chart)
    }
}
