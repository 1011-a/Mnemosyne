import Foundation

/// Projects a subset of columns from parsed CSV/TSV rows for the `csv_select` tool — narrow a
/// wide spreadsheet to just the columns you want, in the order you ask (like SQL SELECT). Pure
/// + deterministic → unit-testable. Pairs with `DelimitedParser` and `MarkdownTable`.
enum CSVProjector {
    /// Keep only `columns` (matched case-insensitively, in the requested order). Returns the
    /// new header + rows, or nil if any requested column isn't in the header.
    static func select(header: [String], rows: [[String]], columns: [String]) -> [[String]]? {
        var indices: [Int] = []
        for col in columns {
            guard let idx = header.firstIndex(where: { $0.caseInsensitiveCompare(col) == .orderedSame })
            else { return nil }
            indices.append(idx)
        }
        guard !indices.isEmpty else { return nil }
        let newHeader = indices.map { header[$0] }
        let newRows = rows.map { row in indices.map { i in i < row.count ? row[i] : "" } }
        return [newHeader] + newRows
    }
}
