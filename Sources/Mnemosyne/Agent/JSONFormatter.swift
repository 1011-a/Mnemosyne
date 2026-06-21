import Foundation

/// Pretty-prints or minifies a JSON string for the `format_json` tool — tidy up minified JSON
/// or compact a sprawling one. Pure + deterministic (sorted keys) → unit-testable. Returns nil
/// for invalid JSON.
enum JSONFormatter {
    static func pretty(_ json: String) -> String? {
        guard let obj = parse(json) else { return nil }
        if let a = obj as? [Any], a.isEmpty { return "[]" }            // avoid "[\n\n]"
        if let d = obj as? [String: Any], d.isEmpty { return "{}" }
        return serialize(obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func minify(_ json: String) -> String? {
        guard let obj = parse(json) else { return nil }
        return serialize(obj, options: [.sortedKeys])
    }

    private static func parse(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        // No .fragmentsAllowed: require a top-level object/array so re-serialization is always valid.
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private static func serialize(_ obj: Any, options: JSONSerialization.WritingOptions) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
