import XCTest
@testable import Mnemosyne

final class CorrelationTests: XCTestCase {

    func testPerfectPositive() {
        let r = Correlation.pearson([1, 2, 3, 4], [2, 4, 6, 8])
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 1.0, accuracy: 1e-9)
        XCTAssertTrue(Correlation.describe(r!).contains("positive"))
    }

    func testPerfectNegative() {
        let r = Correlation.pearson([1, 2, 3, 4], [8, 6, 4, 2])
        XCTAssertEqual(r!, -1.0, accuracy: 1e-9)
        XCTAssertTrue(Correlation.describe(r!).contains("negative"))
    }

    func testNoVarianceOrLengthMismatchReturnsNil() {
        XCTAssertNil(Correlation.pearson([5, 5, 5], [1, 2, 3]))   // x flat → undefined
        XCTAssertNil(Correlation.pearson([1, 2, 3], [1, 2]))      // length mismatch
        XCTAssertNil(Correlation.pearson([1], [1]))               // need >= 2
    }

    func testWeakCorrelationLabel() {
        // Symmetric scatter cancels to r = 0 (cov sums to zero).
        let r = Correlation.pearson([1, 2, 3, 4], [4, 1, 1, 4])
        XCTAssertNotNil(r)
        XCTAssertEqual(r!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(Correlation.describe(r!), "no linear relationship")
    }
}
