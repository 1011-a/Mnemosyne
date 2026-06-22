import Foundation

/// Flags outliers in a number list using Tukey's fences (IQR method) for the `outliers` tool.
/// A value is an outlier when it falls below Q1 − k·IQR or above Q3 + k·IQR (default k = 1.5,
/// the classic "mild" fence). Pure + deterministic → unit-testable. Reuses `Quartiles`.
enum Outliers {
    struct Result {
        let lowerFence: Double
        let upperFence: Double
        let low: [Double]    // values below the lower fence (sorted ascending)
        let high: [Double]   // values above the upper fence (sorted ascending)
    }

    /// Needs at least 4 values for a meaningful quartile split; k must be > 0. Otherwise nil.
    static func detect(_ nums: [Double], k: Double = 1.5) -> Result? {
        guard nums.count >= 4, k > 0, let q = Quartiles.compute(nums) else { return nil }
        let lo = q.q1 - k * q.iqr
        let hi = q.q3 + k * q.iqr
        let sorted = nums.sorted()
        return Result(
            lowerFence: lo,
            upperFence: hi,
            low: sorted.filter { $0 < lo },
            high: sorted.filter { $0 > hi }
        )
    }
}
