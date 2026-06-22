import Foundation

/// Compound-interest future value for the `compound_interest` tool — "what does $X grow to at r%
/// over n years?". FV = P·(1 + r/m)^(m·n), where m is the number of compounding periods per year.
/// Pure + deterministic → unit-testable.
enum CompoundInterest {
    /// Future value of `principal` at `annualRatePct` for `years`, compounded `perYear` times a
    /// year (default 1 = annually). nil for negative principal/years or non-positive perYear.
    /// A 0% rate returns the principal unchanged.
    static func futureValue(principal: Double, annualRatePct: Double,
                            years: Double, perYear: Int = 1) -> Double? {
        guard principal >= 0, years >= 0, perYear > 0 else { return nil }
        let m = Double(perYear)
        let rate = annualRatePct / 100
        return principal * pow(1 + rate / m, m * years)
    }

    /// Interest earned = future value − principal. nil on the same invalid inputs.
    static func interestEarned(principal: Double, annualRatePct: Double,
                               years: Double, perYear: Int = 1) -> Double? {
        guard let fv = futureValue(principal: principal, annualRatePct: annualRatePct,
                                   years: years, perYear: perYear) else { return nil }
        return fv - principal
    }
}
