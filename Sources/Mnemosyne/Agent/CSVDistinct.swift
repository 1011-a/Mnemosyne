import Foundation

/// Lists the unique values in a CSV/TSV column for the `csv_distinct` tool — a SQL SELECT
/// DISTINCT, for exploring what's in a column. Pure + deterministic (sorted unique) →
/// unit-testable. Pairs with `DelimitedParser`.
enum CSVDistinct {
    /// Unique non-empty values of `column` (matched case-insensitively), sorted; nil if the
    /// column isn't found.
    static func values(header: [String], rows: [[String]], column: String) -> [String]? {
        guard let idx = header.firstIndex(where: { $0.caseInsensitiveCompare(column) == .orderedSame })
        else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            let v = (idx < row.count ? row[idx] : "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, seen.insert(v).inserted { out.append(v) }
        }
        return out.sorted()
    }
}
