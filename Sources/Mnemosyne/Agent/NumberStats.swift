import Foundation

/// Descriptive statistics over a list of numbers for the `number_stats` tool — the agent
/// passes values it has in hand ("12, 19, 7, 23") and gets count/sum/mean/median/min/max/
/// range/stdev. Complements `csv_column_stats` (which needs a stored sheet). Pure +
/// deterministic → unit-testable. Standard deviation is the POPULATION σ.
enum NumberStats {
    struct Stats: Equatable {
        let count: Int
        let sum: Double
        let mean: Double
        let median: Double
        let min: Double
        let max: Double
        let stdev: Double
    }

    /// Parse numbers separated by commas, whitespace, or newlines (invalid tokens skipped).
    static func parse(_ data: String) -> [Double] {
        data.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .compactMap { Double($0) }
    }

    static func compute(_ nums: [Double]) -> Stats? {
        guard !nums.isEmpty else { return nil }
        let n = nums.count
        let sorted = nums.sorted()
        let sum = nums.reduce(0, +)
        let mean = sum / Double(n)
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        let variance = nums.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
        return Stats(count: n, sum: sum, mean: mean, median: median,
                     min: sorted.first!, max: sorted.last!, stdev: variance.squareRoot())
    }

    static func report(_ data: String) -> String? {
        guard let s = compute(parse(data)) else { return nil }
        return "\(s.count) values — sum \(fmt(s.sum)), mean \(fmt(s.mean)), median \(fmt(s.median)), "
            + "min \(fmt(s.min)), max \(fmt(s.max)), range \(fmt(s.max - s.min)), stdev \(fmt(s.stdev))."
    }

    /// Whole numbers as ints, otherwise up to 2 decimals with trailing zeros trimmed.
    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
