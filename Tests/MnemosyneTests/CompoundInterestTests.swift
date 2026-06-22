import XCTest
@testable import Mnemosyne

final class CompoundInterestTests: XCTestCase {

    func testAnnualCompounding() {
        // 1000 at 5% for 10 years annually → 1000·1.05^10 ≈ 1628.894627
        XCTAssertEqual(CompoundInterest.futureValue(principal: 1000, annualRatePct: 5, years: 10)!,
                       1628.894626777442, accuracy: 1e-6)
    }

    func testMonthlyCompounding() {
        // 1000 at 12% for 1 year, monthly → 1000·1.01^12 ≈ 1126.825
        XCTAssertEqual(CompoundInterest.futureValue(principal: 1000, annualRatePct: 12, years: 1, perYear: 12)!,
                       1126.825030131969, accuracy: 1e-6)
    }

    func testZeroRateAndInterestEarned() {
        XCTAssertEqual(CompoundInterest.futureValue(principal: 500, annualRatePct: 0, years: 5)!, 500)
        XCTAssertEqual(CompoundInterest.interestEarned(principal: 1000, annualRatePct: 5, years: 10)!,
                       628.894626777442, accuracy: 1e-6)
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(CompoundInterest.futureValue(principal: -100, annualRatePct: 5, years: 10))
        XCTAssertNil(CompoundInterest.futureValue(principal: 100, annualRatePct: 5, years: -1))
        XCTAssertNil(CompoundInterest.futureValue(principal: 100, annualRatePct: 5, years: 10, perYear: 0))
    }
}
