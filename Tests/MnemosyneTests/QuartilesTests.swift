import XCTest
@testable import Mnemosyne

final class QuartilesTests: XCTestCase {

    func testEvenCount() {
        let q = Quartiles.compute([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(q?.q1, 2.5)
        XCTAssertEqual(q?.q2, 4.5)
        XCTAssertEqual(q?.q3, 6.5)
        XCTAssertEqual(q?.iqr, 4)
    }

    func testOddCountExclusiveMedian() {
        let q = Quartiles.compute([1, 2, 3, 4, 5])
        XCTAssertEqual(q?.q1, 1.5)
        XCTAssertEqual(q?.q2, 3)
        XCTAssertEqual(q?.q3, 4.5)
    }

    func testUnsortedInputAndSmall() {
        let q = Quartiles.compute([8, 1, 5, 3])   // sorts internally
        XCTAssertEqual(q?.q2, 4)                    // median of 1,3,5,8 = (3+5)/2
        XCTAssertNil(Quartiles.compute([]))
        let single = Quartiles.compute([7])
        XCTAssertEqual(single?.q2, 7)               // single value → all equal
    }

    func testMedianHelper() {
        XCTAssertEqual(Quartiles.median([1, 2, 3]), 2)
        XCTAssertEqual(Quartiles.median([1, 2, 3, 4]), 2.5)
    }
}
