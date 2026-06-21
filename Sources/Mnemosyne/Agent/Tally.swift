import Foundation

/// Counts occurrences of each distinct value in a list for the `tally` tool — a categorical
/// counterpart to `number_stats` (a SQL GROUP BY over in-context data: statuses, tags, names).
/// Pairs well with `bar_chart`. Pure + deterministic → unit-testable.
enum Tally {
    /// Split on newlines/commas, trim, drop blanks, count; sort by frequency then alphabetically.
    static func count(_ data: String) -> [(value: String, count: Int)] {
        let items = data.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return [] }
        var freq: [String: Int] = [:]
        for v in items { freq[v, default: 0] += 1 }
        return freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (value: $0.key, count: $0.value) }
    }

    static func summary(_ data: String, max: Int = 30) -> String? {
        let counts = count(data)
        guard !counts.isEmpty else { return nil }
        let total = counts.reduce(0) { $0 + $1.count }
        let shown = counts.prefix(max).map { "  \($0.value): \($0.count)" }
        let more = counts.count > max ? ["  …(+\(counts.count - max) more)"] : []
        return "\(total) item(s), \(counts.count) unique:\n" + (shown + more).joined(separator: "\n")
    }
}
