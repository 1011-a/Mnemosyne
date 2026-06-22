import XCTest
@testable import Mnemosyne

final class PercentileTests: XCTestCase {

    func testMedianAndExtremes() {
        let nums = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(Percentile.value(nums, p: 50)!, 3, accuracy: 1e-9)   // median
        XCTAssertEqual(Percentile.value(nums, p: 0)!, 1, accuracy: 1e-9)
        XCTAssertEqual(Percentile.value(nums, p: 100)!, 5, accuracy: 1e-9)
    }

    func testInterpolation() {
        // numpy: percentile([1,2,3,4], 30) == 1.9
        XCTAssertEqual(Percentile.value([1, 2, 3, 4], p: 30)!, 1.9, accuracy: 1e-9)
        // 90th percentile of 1..10 == 9.1
        XCTAssertEqual(Percentile.value(Array(1...10).map(Double.init), p: 90)!, 9.1, accuracy: 1e-9)
    }

    func testClampingAndSingleAndEmpty() {
        XCTAssertEqual(Percentile.value([7], p: 42)!, 7)            // single value
        XCTAssertEqual(Percentile.value([1, 2, 3], p: 250)!, 3)     // clamp >100
        XCTAssertEqual(Percentile.value([1, 2, 3], p: -10)!, 1)     // clamp <0
        XCTAssertNil(Percentile.value([], p: 50))
    }

    func testUnsortedInputHandled() {
        XCTAssertEqual(Percentile.value([5, 1, 3, 2, 4], p: 25)!, 2, accuracy: 1e-9)
    }
}
