import Foundation

/// Filters a JSON array of objects by a predicate for the `json_filter` tool — 'status =
/// active', 'score >= 80' — the JSON analog of `csv_filter`. Composes the tested `JSONTable`
/// (JSON → rows) and `RowFilter` (predicate). Pure → unit-testable.
enum JSONFilter {
    enum Result {
        case ok([[String]])           // header + matched rows
        case badJSON
        case badPredicate
        case noColumn([String])
    }

    static func filter(_ jsonText: String, where expr: String) -> Result {
        guard let rows = JSONTable.rows(from: jsonText), let header = rows.first else { return .badJSON }
        switch RowFilter.evaluate(headers: header, rows: Array(rows.dropFirst()), expr: expr) {
        case .badPredicate: return .badPredicate
        case .noColumn(let cols): return .noColumn(cols)
        case .ok(_, let matched): return .ok([header] + matched)
        }
    }
}
