import Foundation

/// Transposes parsed CSV/TSV rows (swaps rows and columns) for the `csv_transpose` tool —
/// flip a small table so each original column becomes a row. Ragged rows are padded. Pure +
/// deterministic → unit-testable.
enum CSVTranspose {
    static func transpose(_ rows: [[String]]) -> [[String]] {
        guard !rows.isEmpty else { return [] }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return [] }
        return (0..<cols).map { c in
            rows.map { r in c < r.count ? r[c] : "" }
        }
    }
}
