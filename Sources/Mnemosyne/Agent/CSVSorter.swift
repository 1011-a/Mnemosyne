import Foundation

/// Sorts parsed CSV/TSV rows by a column for the `csv_sort` tool — order a spreadsheet by
/// name, amount, date, etc. Pure + deterministic → unit-testable. Pairs with `DelimitedParser`
/// (rows in) and `MarkdownTable` (render out).
enum CSVSorter {
    /// Sort `rows` by the named column (case-insensitive). `numeric` compares parsed numbers
    /// (currency/commas tolerated) and falls back to text when a cell isn't numeric. Returns
    /// header + sorted rows, or nil if the column isn't found.
    static func sort(header: [String], rows: [[String]], column: String,
                     descending: Bool = false, numeric: Bool = false) -> [[String]]? {
        guard let idx = header.firstIndex(where: { $0.caseInsensitiveCompare(column) == .orderedSame })
        else { return nil }

        func cell(_ r: [String]) -> String { idx < r.count ? r[idx] : "" }

        var sorted = rows.sorted { a, b in
            let ca = cell(a), cb = cell(b)
            if numeric, let na = number(ca), let nb = number(cb) {
                return na != nb ? na < nb : ca < cb
            }
            let la = ca.lowercased(), lb = cb.lowercased()
            return la != lb ? la < lb : ca < cb
        }
        if descending { sorted.reverse() }
        return [header] + sorted
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: ""))
    }
}
