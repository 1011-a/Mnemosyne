import Foundation

/// Computes aggregate statistics for one column of a parsed CSV/TSV sheet — powers the
/// `csv_column_stats` tool so the agent can actually ANSWER questions about a spreadsheet
/// ("total revenue?", "most common status?"), not just preview it. Pure + deterministic →
/// unit-testable. Pairs with `DelimitedParser` (which supplies the rows).
enum ColumnAnalyzer {
    struct NumericStats: Equatable {
        let n: Int
        let sum: Double
        let mean: Double
        let min: Double
        let max: Double
    }

    struct Stats: Equatable {
        let column: String
        let count: Int                          // non-empty values
        let unique: Int
        let numeric: NumericStats?              // non-nil only when EVERY value is numeric
        let top: [(value: String, count: Int)]  // most frequent values (categorical view)

        static func == (a: Stats, b: Stats) -> Bool {
            a.column == b.column && a.count == b.count && a.unique == b.unique
                && a.numeric == b.numeric && a.top.map(\.value) == b.top.map(\.value)
                && a.top.map(\.count) == b.top.map(\.count)
        }
    }

    /// Analyze `column` (matched case-insensitively) over the data rows. Returns nil if the
    /// column name isn't in the header. `topK` caps the categorical frequency list.
    static func analyze(headers: [String], rows: [[String]], column: String, topK: Int = 5) -> Stats? {
        guard let idx = headers.firstIndex(where: { $0.caseInsensitiveCompare(column) == .orderedSame })
        else { return nil }

        let values = rows.compactMap { row -> String? in
            guard row.indices.contains(idx) else { return nil }
            let v = row[idx].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }

        // Numeric only when every non-empty value parses (after stripping $, %, commas).
        let nums = values.compactMap { numeric($0) }
        let numericStats: NumericStats?
        if !values.isEmpty, nums.count == values.count {
            let sum = nums.reduce(0, +)
            numericStats = NumericStats(n: nums.count, sum: sum, mean: sum / Double(nums.count),
                                        min: nums.min() ?? 0, max: nums.max() ?? 0)
        } else {
            numericStats = nil
        }

        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        // Most frequent first; ties broken by value ascending for deterministic output.
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(topK)
            .map { (value: $0.key, count: $0.value) }

        return Stats(column: headers[idx], count: values.count, unique: counts.count,
                     numeric: numericStats, top: Array(top))
    }

    /// Parse a numeric cell, tolerating `$`, `%`, thousands separators, and surrounding spaces.
    static func numeric(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for token in ["$", "€", "£", "%", ","] { s = s.replacingOccurrences(of: token, with: "") }
        return Double(s)
    }

    /// A human-readable tool reply, or nil when the column is missing.
    static func report(headers: [String], rows: [[String]], column: String, topK: Int = 5) -> String? {
        guard let s = analyze(headers: headers, rows: rows, column: column, topK: topK) else { return nil }
        var lines = ["Column '\(s.column)' — \(s.count) value(s), \(s.unique) unique."]
        if let n = s.numeric {
            let f = { (d: Double) in
                d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
            }
            lines.append("Numeric: sum=\(f(n.sum)), mean=\(f(n.mean)), min=\(f(n.min)), max=\(f(n.max)).")
        }
        if !s.top.isEmpty {
            let top = s.top.map { "\($0.value) (\($0.count))" }.joined(separator: ", ")
            lines.append("Top values: \(top).")
        }
        return lines.joined(separator: "\n")
    }
}
