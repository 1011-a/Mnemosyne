import XCTest
@testable import Mnemosyne

final class LoanPaymentTests: XCTestCase {

    func testStandardMortgage() {
        // 100,000 at 6% over 30 years → ~599.55/month
        XCTAssertEqual(LoanPayment.monthlyPayment(principal: 100_000, annualRatePct: 6, years: 30)!,
                       599.55, accuracy: 0.01)
    }

    func testZeroInterestIsPrincipalOverMonths() {
        // 1200 at 0% over 1 year → 100/month
        XCTAssertEqual(LoanPayment.monthlyPayment(principal: 1200, annualRatePct: 0, years: 1)!, 100, accuracy: 1e-9)
    }

    func testTotalInterest() {
        // 30-year 100k@6%: total paid ≈ 599.55·360 ≈ 215,838 → interest ≈ 115,838
        let interest = LoanPayment.totalInterest(principal: 100_000, annualRatePct: 6, years: 30)!
        XCTAssertEqual(interest, 115_838, accuracy: 5)
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(LoanPayment.monthlyPayment(principal: -1, annualRatePct: 5, years: 10))
        XCTAssertNil(LoanPayment.monthlyPayment(principal: 1000, annualRatePct: 5, years: 0))
    }
}
