import Foundation

/// Renders a horizontal ASCII bar chart for the `bar_chart` tool — lets the agent VISUALIZE
/// numbers it computed (column stats, activity trends, tallies) directly in the chat, no image
/// needed. Input is "label: value" pairs (comma- or newline-separated). Pure + deterministic →
/// unit-testable.
enum AsciiChart {
    /// Parse "label: value" pairs (comma- or newline-separated). Invalid entries are skipped.
    static func parse(_ data: String) -> [(label: String, value: Double)] {
        data.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .compactMap { piece -> (String, Double)? in
                guard let colon = piece.lastIndex(of: ":") else { return nil }
                let label = piece[..<colon].trimmingCharacters(in: .whitespaces)
                // Comma is the pair separator, so values can't carry a thousands separator.
                let raw = piece[piece.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, let value = Double(raw) else { return nil }
                return (label, value)
            }
    }

    /// Render aligned bars scaled so the largest value fills `width` blocks.
    static func bars(_ pairs: [(label: String, value: Double)], width: Int = 30) -> String {
        guard !pairs.isEmpty else { return "" }
        let labelWidth = pairs.map { $0.label.count }.max() ?? 0
        let maxValue = pairs.map { $0.value }.max() ?? 0
        return pairs.map { pair in
            let padded = pair.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let n = maxValue > 0 ? Int((pair.value / maxValue * Double(width)).rounded()) : 0
            let bar = String(repeating: "█", count: max(0, n))
            return "\(padded) │\(bar) \(format(pair.value))"
        }.joined(separator: "\n")
    }

    static func render(_ data: String, width: Int = 30) -> String? {
        let pairs = parse(data)
        guard !pairs.isEmpty else { return nil }
        return bars(pairs, width: width)
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
