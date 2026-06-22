import Foundation

/// Fixed-rate loan amortization for the `loan_payment` tool — the level monthly payment that
/// pays off a principal over a term: M = P·r·(1+r)^n / ((1+r)^n − 1), where r is the monthly rate
/// and n the number of payments. A 0% loan is simply P/n. Pure + deterministic → unit-testable.
/// Complements [[CompoundInterest]].
enum LoanPayment {
    /// Level monthly payment for `principal` at `annualRatePct` over `years`. nil for
    /// principal < 0 or years ≤ 0.
    static func monthlyPayment(principal: Double, annualRatePct: Double, years: Double) -> Double? {
        guard principal >= 0, years > 0 else { return nil }
        let n = years * 12
        let r = annualRatePct / 100 / 12
        if r == 0 { return principal / n }
        let growth = pow(1 + r, n)
        return principal * r * growth / (growth - 1)
    }

    /// Total interest paid over the life of the loan (payment·n − principal). nil on bad inputs.
    static func totalInterest(principal: Double, annualRatePct: Double, years: Double) -> Double? {
        guard let m = monthlyPayment(principal: principal, annualRatePct: annualRatePct, years: years) else { return nil }
        return m * years * 12 - principal
    }
}
