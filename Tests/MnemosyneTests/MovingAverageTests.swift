import XCTest
@testable import Mnemosyne

final class MovingAverageTests: XCTestCase {

    func testWindowOfThree() {
        let ma = MovingAverage.simple([1, 2, 3, 4, 5], window: 3)
        XCTAssertEqual(ma, [2, 3, 4])   // means of (1,2,3),(2,3,4),(3,4,5)
    }

    func testWindowOfOneIsIdentity() {
        XCTAssertEqual(MovingAverage.simple([7, 8, 9], window: 1), [7, 8, 9])
    }

    func testWindowEqualsCountGivesOverallMean() {
        let ma = MovingAverage.simple([2, 4, 6], window: 3)
        XCTAssertEqual(ma, [4])
    }

    func testInvalidWindowReturnsNil() {
        XCTAssertNil(MovingAverage.simple([1, 2, 3], window: 0))
        XCTAssertNil(MovingAverage.simple([1, 2, 3], window: 4))   // window > count
        XCTAssertNil(MovingAverage.simple([], window: 1))
    }
}
