import Foundation

/// Converts parsed CSV/TSV rows into a JSON array of objects for the `csv_to_json` tool —
/// a common data-wrangling step (feed an export to an API, or just reshape it). Values stay
/// strings (CSV is untyped text); object keys come from the header row. Pure + deterministic
/// (sorted keys) → unit-testable. Pairs with `DelimitedParser` (the rows).
enum CSVConverter {
    /// Header row → object keys; each later row → an object. Missing cells become "", extra
    /// cells are ignored. Header-only input → "[]". Nil only if there are no rows at all.
    static func toJSON(_ rows: [[String]]) -> String? {
        guard let header = rows.first else { return nil }
        let objects: [[String: String]] = rows.dropFirst().map { row in
            var dict: [String: String] = [:]
            for (i, key) in header.enumerated() where !key.isEmpty {
                dict[key] = i < row.count ? row[i] : ""
            }
            return dict
        }
        guard !objects.isEmpty else { return "[]" }   // pretty-printed empty array is "[\n\n]"; keep it clean
        guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
