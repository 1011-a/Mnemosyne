import Foundation

/// Period-over-period percentage change of a number series for the `pct_change` tool — e.g. how
/// each month's revenue compares to the previous month. Returns one value per step (length n−1).
/// A step where the previous value is 0 is undefined (division by zero) → nil for that step. Pure
/// + deterministic → unit-testable. Pairs with `NumberStats.parse` and [[RunningTotal]].
enum PctChange {
    /// nil for a list shorter than 2; otherwise one `Double?` per consecutive pair (nil when the
    /// earlier value is 0).
    static func series(_ nums: [Double]) -> [Double?]? {
        guard nums.count >= 2 else { return nil }
        return (1..<nums.count).map { i in
            let prev = nums[i - 1]
            return prev == 0 ? nil : (nums[i] - prev) / prev * 100
        }
    }
}
