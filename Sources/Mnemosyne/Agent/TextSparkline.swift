import Foundation

/// Renders a compact one-line Unicode sparkline for the `sparkline` tool — a tiny inline
/// trend (`▁▂▃▄▅▆▇█`) for a number series the agent has (activity over time, a column of
/// values). Complements `bar_chart` (labeled horizontal bars) when a glanceable trend is
/// enough. Pure + deterministic → unit-testable.
///
/// Named `TextSparkline` to avoid clashing with the design-system `Sparkline` SwiftUI view.
enum TextSparkline {
    private static let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// Parse numbers separated by commas/whitespace/newlines (invalid tokens skipped).
    static func parse(_ data: String) -> [Double] {
        data.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .compactMap { Double($0) }
    }

    /// Map each value to one of 8 blocks, scaled between the series min and max.
    static func spark(_ nums: [Double]) -> String {
        guard !nums.isEmpty else { return "" }
        let lo = nums.min()!, hi = nums.max()!
        let range = hi - lo
        return nums.map { v -> String in
            guard range > 0 else { return blocks[3] }   // flat series → mid block
            let idx = Int(((v - lo) / range * Double(blocks.count - 1)).rounded())
            return blocks[Swift.min(Swift.max(idx, 0), blocks.count - 1)]
        }.joined()
    }

    static func render(_ data: String) -> String? {
        let nums = parse(data)
        guard !nums.isEmpty else { return nil }
        return "\(spark(nums))  (\(fmt(nums.min()!))→\(fmt(nums.max()!)) over \(nums.count) points)"
    }

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
