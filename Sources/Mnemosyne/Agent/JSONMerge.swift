import Foundation

/// Merges two JSON objects for the `json_merge` tool — combine configs/settings, with the
/// second object winning on conflicts. Deep merge recurses into nested objects; shallow
/// replaces top-level keys. Pure + deterministic (sorted keys) → unit-testable.
enum JSONMerge {
    /// Merge `b` into `a` (both must be top-level objects). Returns pretty JSON, or nil if
    /// either side isn't a JSON object.
    static func merge(_ a: String, _ b: String, deep: Bool = true) -> String? {
        guard let da = object(a), let db = object(b) else { return nil }
        let merged = mergeDicts(da, db, deep: deep)
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private static func mergeDicts(_ a: [String: Any], _ b: [String: Any], deep: Bool) -> [String: Any] {
        var result = a
        for (k, v) in b {
            if deep, let av = result[k] as? [String: Any], let bv = v as? [String: Any] {
                result[k] = mergeDicts(av, bv, deep: true)
            } else {
                result[k] = v
            }
        }
        return result
    }

    private static func object(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
