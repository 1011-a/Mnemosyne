import Foundation

/// Tip and bill-splitting math for the `tip` tool — tip amount, grand total, and per-person share.
/// Pure + deterministic → unit-testable.
enum TipCalculator {
    struct Result: Equatable {
        let tip: Double
        let total: Double
        let perPerson: Double
    }

    /// Tip `percent` on `bill`, split among `people` (default 1). nil for a negative bill,
    /// negative percent, or fewer than 1 person.
    static func compute(bill: Double, percent: Double, people: Int = 1) -> Result? {
        guard bill >= 0, percent >= 0, people >= 1 else { return nil }
        let tip = bill * percent / 100
        let total = bill + tip
        return Result(tip: tip, total: total, perPerson: total / Double(people))
    }
}
