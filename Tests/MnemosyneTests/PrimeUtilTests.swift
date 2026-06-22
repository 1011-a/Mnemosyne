import XCTest
@testable import Mnemosyne

final class PrimeUtilTests: XCTestCase {

    func testIsPrime() {
        XCTAssertTrue(PrimeUtil.isPrime(2))
        XCTAssertTrue(PrimeUtil.isPrime(3))
        XCTAssertTrue(PrimeUtil.isPrime(17))
        XCTAssertTrue(PrimeUtil.isPrime(7919))
        XCTAssertFalse(PrimeUtil.isPrime(1))
        XCTAssertFalse(PrimeUtil.isPrime(0))
        XCTAssertFalse(PrimeUtil.isPrime(-7))
        XCTAssertFalse(PrimeUtil.isPrime(4))
        XCTAssertFalse(PrimeUtil.isPrime(91))   // 7 × 13
    }

    func testFactorize() {
        XCTAssertEqual(PrimeUtil.factorize(60), [2, 2, 3, 5])
        XCTAssertEqual(PrimeUtil.factorize(17), [17])    // prime → itself
        XCTAssertEqual(PrimeUtil.factorize(1), [])
        XCTAssertEqual(PrimeUtil.factorize(64), [2, 2, 2, 2, 2, 2])
    }

    func testFactorizeProductReconstructsInput() {
        let n = 360
        XCTAssertEqual(PrimeUtil.factorize(n).reduce(1, *), n)
    }
}
