import Foundation

/// Cumulative (running) totals of a number series for the `running_total` tool — each output is
/// the sum of all values up to and including that position. The last value is the grand total.
/// Pure + deterministic → unit-testable. Pairs with `NumberStats.parse` and `moving_average`.
enum RunningTotal {
    /// Returns one cumulative sum per input value (same length). Empty input → empty.
    static func cumulative(_ nums: [Double]) -> [Double] {
        var sum = 0.0
        return nums.map { sum += $0; return sum }
    }
}
