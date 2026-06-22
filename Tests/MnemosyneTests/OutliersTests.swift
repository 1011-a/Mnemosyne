import XCTest
@testable import Mnemosyne

final class OutliersTests: XCTestCase {

    func testCatchesAHighOutlier() {
        // Tight cluster plus one far-out value.
        let r = Outliers.detect([10, 11, 12, 13, 14, 100])
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.high, [100])
        XCTAssertEqual(r?.low, [])
    }

    func testCatchesALowOutlier() {
        let r = Outliers.detect([-50, 20, 21, 22, 23, 24])
        XCTAssertEqual(r?.low, [-50])
        XCTAssertEqual(r?.high, [])
    }

    func testNoOutliersInUniformData() {
        let r = Outliers.detect([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(r?.low, [])
        XCTAssertEqual(r?.high, [])
    }

    func testTooFewValuesOrBadKReturnsNil() {
        XCTAssertNil(Outliers.detect([1, 2, 3]))        // need >= 4
        XCTAssertNil(Outliers.detect([1, 2, 3, 4], k: 0))
    }
}
