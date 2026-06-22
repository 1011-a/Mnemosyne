import Foundation

/// Lists every unique key PATH in a JSON document for the `json_keys` tool — a flat, sorted
/// view of the structure ("user.name", "items[].id") to pair with `json_value`. Distinct from
/// `inspect_json` (a shape/type tree). Pure + deterministic (sorted) → unit-testable.
enum JSONKeys {
    static func paths(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var set = Set<String>()
        collect(root, prefix: "", into: &set)
        return set.sorted()
    }

    private static func collect(_ value: Any, prefix: String, into set: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict {
                let path = prefix.isEmpty ? k : "\(prefix).\(k)"
                set.insert(path)
                collect(v, prefix: path, into: &set)
            }
        } else if let arr = value as? [Any] {
            let path = prefix + "[]"
            for el in arr { collect(el, prefix: path, into: &set) }
        }
    }
}
