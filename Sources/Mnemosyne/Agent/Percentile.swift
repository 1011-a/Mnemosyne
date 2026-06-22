import Foundation

/// Computes an arbitrary percentile of a number list for the `percentile` tool — e.g. the 90th
/// percentile of response times. Uses linear interpolation between closest ranks (the same method
/// as NumPy's default), so it generalizes the quartiles. Pure + deterministic → unit-testable.
/// Pairs with `NumberStats.parse` and [[Quartiles]].
enum Percentile {
    /// The `p`-th percentile (p clamped to 0…100) of `nums`. nil for an empty list.
    static func value(_ nums: [Double], p: Double) -> Double? {
        guard !nums.isEmpty else { return nil }
        let sorted = nums.sorted()
        if sorted.count == 1 { return sorted[0] }
        let pct = Swift.max(0, Swift.min(100, p))
        let rank = pct / 100 * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = rank - Double(lower)
        return sorted[lower] + frac * (sorted[upper] - sorted[lower])
    }
}
