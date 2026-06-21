import Foundation

/// Describes the SHAPE of a JSON document for the `inspect_json` tool — configs, API
/// exports, and logs are often JSON, and the agent needs to grasp the schema (which keys,
/// what types, how deeply nested) before reasoning about it. Produces an indented type
/// outline, not the data itself. Pure + deterministic (object keys sorted) → unit-testable.
enum JSONInspector {

    /// An indented schema outline of the JSON in `text`, or nil if it doesn't parse.
    static func shape(_ text: String, maxDepth: Int = 4, maxKeys: Int = 30) -> String? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        var lines = [summaryType(root)]
        lines += describe(root, depth: 1, maxDepth: maxDepth, maxKeys: maxKeys, indent: "  ")
        return lines.joined(separator: "\n")
    }

    /// The JSON type of a single value (`boolean` distinguished from `number`).
    static func typeName(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? "boolean" : "number"
        }
        if v is String { return "string" }
        if v is [Any] { return "array" }
        if v is [String: Any] { return "object" }
        return "value"
    }

    /// A one-line type summary: containers report their size + element type.
    static func summaryType(_ v: Any) -> String {
        if let arr = v as? [Any] {
            let elem = arr.first.map { typeName($0) } ?? "empty"
            return "array[\(arr.count)] of \(arr.isEmpty ? "empty" : elem)"
        }
        if let obj = v as? [String: Any] {
            return "object (\(obj.count) key\(obj.count == 1 ? "" : "s"))"
        }
        return typeName(v)
    }

    private static func describe(_ v: Any, depth: Int, maxDepth: Int, maxKeys: Int, indent: String) -> [String] {
        if let dict = v as? [String: Any] {
            var lines: [String] = []
            let keys = dict.keys.sorted()
            for k in keys.prefix(maxKeys) {
                let val = dict[k]!
                lines.append("\(indent)\(k): \(summaryType(val))")
                if depth < maxDepth, val is [String: Any] || val is [Any] {
                    lines += describe(val, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys, indent: indent + "  ")
                }
            }
            if keys.count > maxKeys { lines.append("\(indent)…(+\(keys.count - maxKeys) more keys)") }
            return lines
        }
        // For an array, show the shape of its first element as a representative.
        if let arr = v as? [Any], let first = arr.first, depth < maxDepth,
           first is [String: Any] || first is [Any] {
            return describe(first, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys, indent: indent)
        }
        return []
    }
}
