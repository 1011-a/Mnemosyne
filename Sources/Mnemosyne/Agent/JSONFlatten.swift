import Foundation

/// Flattens a nested JSON document into dotted `path → value` leaves for the `json_flatten`
/// tool — 'a.b', 'x[0]' — a flat, scannable view of every value. Distinct from `JSONKeys`
/// (keys only). Pure + deterministic (sorted by path) → unit-testable. Reuses `JSONPath.render`.
enum JSONFlatten {
    static func flatten(_ text: String) -> [(path: String, value: String)]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var out: [(String, String)] = []
        collect(root, prefix: "", into: &out)
        return out.sorted { $0.0 < $1.0 }.map { (path: $0.0, value: $0.1) }
    }

    private static func collect(_ value: Any, prefix: String, into out: inout [(String, String)]) {
        if let dict = value as? [String: Any] {
            for k in dict.keys.sorted() {
                let path = prefix.isEmpty ? k : "\(prefix).\(k)"
                collect(dict[k]!, prefix: path, into: &out)
            }
        } else if let arr = value as? [Any] {
            for (i, el) in arr.enumerated() {
                collect(el, prefix: "\(prefix)[\(i)]", into: &out)
            }
        } else {
            out.append((prefix, JSONPath.render(value)))
        }
    }
}
