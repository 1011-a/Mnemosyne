import Foundation

/// Extracts every span of text between a start and end marker for the `extract_between` tool —
/// pull fields out of templated/markup text (e.g. between `<b>` and `</b>`, or `[` and `]`).
/// Non-overlapping, left to right. Pure + deterministic → unit-testable.
enum TextBetween {
    static func extract(_ text: String, start: String, end: String, max: Int = 100) -> [String] {
        guard !start.isEmpty, !end.isEmpty, !text.isEmpty else { return [] }
        var out: [String] = []
        var from = text.startIndex
        while let s = text.range(of: start, range: from..<text.endIndex),
              let e = text.range(of: end, range: s.upperBound..<text.endIndex) {
            out.append(String(text[s.upperBound..<e.lowerBound]))
            if out.count >= max { break }
            from = e.upperBound
        }
        return out
    }

    static func summary(_ text: String, start: String, end: String, max: Int = 100) -> String? {
        let spans = extract(text, start: start, end: end, max: max)
        guard !spans.isEmpty else { return nil }
        let body = spans.map { "  • \($0)" }.joined(separator: "\n")
        return "\(spans.count) span(s) between '\(start)' and '\(end)':\n\(body)"
    }
}
