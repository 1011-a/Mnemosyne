import Foundation

/// Converts a JSON document into table rows for the `json_to_table` tool — API exports are
/// usually arrays of objects, and a table is the clearest way to see them. Pairs with
/// `MarkdownTable.tableFrom` (rendering) and reuses `JSONPath.render` (cell values). Pure +
/// deterministic (keys sorted) → unit-testable.
enum JSONTable {
    /// Build rows (first row = header) from JSON, or nil if it can't sensibly tabulate:
    /// - array of objects → a column per key (sorted union), a row per object;
    /// - array of scalars → a single `value` column;
    /// - single object   → a `key | value` table.
    static func rows(from text: String) -> [[String]]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        if let arr = root as? [Any] {
            guard !arr.isEmpty else { return nil }
            let objects = arr.compactMap { $0 as? [String: Any] }
            if objects.count == arr.count {
                let keys = Set(objects.flatMap { $0.keys }).sorted()
                var out: [[String]] = [keys]
                for o in objects {
                    out.append(keys.map { k in o[k].map { JSONPath.render($0) } ?? "" })
                }
                return out
            }
            // Array of scalars (or mixed) → one column.
            return [["value"]] + arr.map { [JSONPath.render($0)] }
        }

        if let obj = root as? [String: Any], !obj.isEmpty {
            let keys = obj.keys.sorted()
            return [["key", "value"]] + keys.map { [$0, JSONPath.render(obj[$0]!)] }
        }
        return nil
    }
}
