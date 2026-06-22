import Foundation

/// Pulls PERCENTAGES out of a document for the `extract_percentages` tool — stats/report notes
/// ("45%", "12.5 %", "-3%") — and summarizes them (count, average, min, max). All occurrences
/// are kept (not deduped) so the stats reflect the document. Pure + deterministic →
/// unit-testable.
enum PercentExtractor {
    static func values(_ text: String, max: Int = 200) -> [(text: String, value: Double)] {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(pattern: #"(-?\d+(?:\.\d+)?)\s*%"#) else { return [] }
        let ns = text as NSString
        var out: [(String, Double)] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let v = Double(ns.substring(with: m.range(at: 1))) else { continue }
            out.append((ns.substring(with: m.range).trimmingCharacters(in: .whitespaces), v))
            if out.count >= max { break }
        }
        return out
    }

    static func summary(_ text: String, max: Int = 200) -> String? {
        let vs = values(text, max: max)
        guard !vs.isEmpty else { return nil }
        let nums = vs.map(\.value)
        let avg = nums.reduce(0, +) / Double(nums.count)
        return "\(vs.count) percentage(s): \(vs.map(\.text).joined(separator: ", ")). "
            + "avg \(fmt(avg))%, min \(fmt(nums.min()!))%, max \(fmt(nums.max()!))%."
    }

    private static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
