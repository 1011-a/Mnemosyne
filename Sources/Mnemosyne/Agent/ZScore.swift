import Foundation

/// Standard (z) scores for the `z_score` tool — how many standard deviations a value sits from the
/// mean of a dataset. Uses the population standard deviation (÷n), the convention for
/// standardizing a known set. Pure + deterministic → unit-testable. Pairs with `NumberStats.parse`
/// and [[Outliers]].
enum ZScore {
    /// Population mean and standard deviation. nil for an empty list.
    static func meanStd(_ nums: [Double]) -> (mean: Double, std: Double)? {
        guard !nums.isEmpty else { return nil }
        let n = Double(nums.count)
        let mean = nums.reduce(0, +) / n
        let variance = nums.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (mean, variance.squareRoot())
    }

    /// z-score of `target` against the distribution of `nums`. nil if the list is empty or has zero
    /// spread (every value identical → no meaningful z).
    static func score(of target: Double, in nums: [Double]) -> Double? {
        guard let (mean, std) = meanStd(nums), std > 0 else { return nil }
        return (target - mean) / std
    }

    /// z-score of every value in the list (standardized series). nil if empty or zero spread.
    static func standardize(_ nums: [Double]) -> [Double]? {
        guard let (mean, std) = meanStd(nums), std > 0 else { return nil }
        return nums.map { ($0 - mean) / std }
    }
}
