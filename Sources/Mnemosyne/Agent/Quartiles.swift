import Foundation

/// Quartiles and interquartile range for the `quartiles` tool — Q1, median (Q2), Q3, IQR over
/// a list of numbers (exclusive method: the median is excluded from each half for odd counts).
/// Pure + deterministic → unit-testable. Pairs with `NumberStats.parse`.
enum Quartiles {
    static func compute(_ nums: [Double]) -> (q1: Double, q2: Double, q3: Double, iqr: Double)? {
        guard !nums.isEmpty else { return nil }
        let s = nums.sorted()
        let half = s.count / 2
        let q2 = median(s)
        let lower = Array(s.prefix(half))
        let upper = Array(s.suffix(half))
        let q1 = lower.isEmpty ? q2 : median(lower)
        let q3 = upper.isEmpty ? q2 : median(upper)
        return (q1, q2, q3, q3 - q1)
    }

    /// Median of an already-sorted array (0 for empty).
    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
