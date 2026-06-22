import Foundation

/// Plucks one field from every object in a JSON array for the `json_pluck` tool — e.g. all
/// `email` values from a list of records. Pure + deterministic → unit-testable. Reuses
/// `JSONPath.render` for value formatting.
enum JSONPluck {
    /// Returns the `key` value of each object in the top-level array (objects lacking the key
    /// are skipped), or nil if the JSON isn't a top-level array.
    static func pluck(_ text: String, key: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        var out: [String] = []
        for el in arr {
            if let obj = el as? [String: Any], let v = obj[key] {
                out.append(JSONPath.render(v))
            }
        }
        return out
    }
}
