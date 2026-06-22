import Foundation

/// Removes duplicate rows from parsed CSV/TSV data for the `csv_dedupe` tool — clean a sheet
/// by exact row, or keep the first row per key column. Pure + deterministic → unit-testable.
/// Pairs with `DelimitedParser` and `MarkdownTable`.
enum CSVDedupe {
    /// Dedupe `rows`. With `keyColumn` nil, an exact whole-row match is a duplicate; otherwise
    /// the first row for each value of that column is kept. Returns the kept rows + how many
    /// were removed, or nil if `keyColumn` is given but not found.
    static func dedupe(header: [String], rows: [[String]], keyColumn: String?) -> (rows: [[String]], removed: Int)? {
        var keyIdx: Int?
        if let kc = keyColumn, !kc.isEmpty {
            guard let i = header.firstIndex(where: { $0.caseInsensitiveCompare(kc) == .orderedSame }) else { return nil }
            keyIdx = i
        }

        var seen = Set<String>()
        var out: [[String]] = []
        var removed = 0
        for row in rows {
            let key: String
            if let ki = keyIdx {
                key = ki < row.count ? row[ki] : ""
            } else {
                key = row.joined(separator: "\u{1}")   // unit separator unlikely in data
            }
            if seen.insert(key).inserted { out.append(row) } else { removed += 1 }
        }
        return (out, removed)
    }
}
