import Foundation

/// Buckets numbers into bins and renders a text histogram for the `histogram` tool — see the
/// distribution of a number list. Pure + deterministic → unit-testable. Pairs with
/// `NumberStats.parse`.
enum Histogram {
    /// Divide [min,max] into `count` equal bins and tally values; the max value lands in the
    /// last bin. All-equal values → a single bin. Empty / count<1 → nil.
    static func bins(_ nums: [Double], count: Int = 10) -> [(range: String, count: Int)]? {
        guard !nums.isEmpty, count > 0 else { return nil }
        let lo = nums.min()!, hi = nums.max()!
        if lo == hi { return [("\(fmt(lo))", nums.count)] }
        let width = (hi - lo) / Double(count)
        var counts = Array(repeating: 0, count: count)
        for v in nums {
            var idx = Int((v - lo) / width)
            if idx >= count { idx = count - 1 }
            counts[idx] += 1
        }
        return (0..<count).map { i in
            ("\(fmt(lo + Double(i) * width))–\(fmt(lo + Double(i + 1) * width))", counts[i])
        }
    }

    static func chart(_ bins: [(range: String, count: Int)], width: Int = 30) -> String {
        guard !bins.isEmpty else { return "" }
        let maxC = bins.map(\.count).max() ?? 0
        let labelW = bins.map { $0.range.count }.max() ?? 0
        return bins.map { b in
            let n = maxC > 0 ? Int((Double(b.count) / Double(maxC) * Double(width)).rounded()) : 0
            let label = b.range.padding(toLength: labelW, withPad: " ", startingAt: 0)
            return "\(label) │\(String(repeating: "█", count: n)) \(b.count)"
        }.joined(separator: "\n")
    }

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}
