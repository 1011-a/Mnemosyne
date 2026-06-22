import XCTest
@testable import Mnemosyne

final class ZScoreTests: XCTestCase {

    func testMeanStd() {
        let r = ZScore.meanStd([1, 2, 3, 4, 5])
        XCTAssertEqual(r?.mean, 3)
        XCTAssertEqual(r!.std, 2.0.squareRoot(), accuracy: 1e-9)   // population variance = 2
    }

    func testScoreOfTarget() {
        // mean 3, std √2 → z(5) = 2/√2 = √2
        XCTAssertEqual(ZScore.score(of: 5, in: [1, 2, 3, 4, 5])!, 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(ZScore.score(of: 3, in: [1, 2, 3, 4, 5])!, 0, accuracy: 1e-9)   // at the mean
    }

    func testStandardizeIsZeroMean() {
        let zs = ZScore.standardize([10, 20, 30, 40])!
        XCTAssertEqual(zs.reduce(0, +), 0, accuracy: 1e-9)
        XCTAssertEqual(zs.count, 4)
    }

    func testZeroSpreadAndEmptyAreNil() {
        XCTAssertNil(ZScore.score(of: 5, in: [5, 5, 5]))   // std 0
        XCTAssertNil(ZScore.standardize([7, 7]))
        XCTAssertNil(ZScore.meanStd([]))
        XCTAssertNil(ZScore.score(of: 1, in: []))
    }
}
