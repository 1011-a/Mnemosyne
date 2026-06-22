import XCTest
@testable import Mnemosyne

final class RunningTotalTests: XCTestCase {

    func testCumulativeSums() {
        XCTAssertEqual(RunningTotal.cumulative([1, 2, 3, 4]), [1, 3, 6, 10])
    }

    func testLastValueIsGrandTotal() {
        let r = RunningTotal.cumulative([10, -4, 7])
        XCTAssertEqual(r.last, 13)          // 10 + (-4) + 7
        XCTAssertEqual(r, [10, 6, 13])
    }

    func testSameLengthAsInput() {
        let input = [2.5, 2.5, 2.5]
        XCTAssertEqual(RunningTotal.cumulative(input).count, input.count)
        XCTAssertEqual(RunningTotal.cumulative(input), [2.5, 5.0, 7.5])
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(RunningTotal.cumulative([]), [])
    }
}
