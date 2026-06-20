import Foundation

/// Flattens a `.json` file (config, API export, app data) into readable
/// "key.path: value" lines so it's searchable and answerable, instead of an
/// opaque blob. Pure; `parse` is unit-testable on raw `Data`. Keys are sorted
/// for deterministic output; nulls are dropped; booleans render as true/false.
enum JsonExtractor {
    static func isJson(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json"
    }

    static func extract(_ url: URL) throws -> String {
        parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return "" }
        var lines: [String] = []
        flatten(root, prefix: "", into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func flatten(_ value: Any, prefix: String, into lines: inout [String]) {
        switch value {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                flatten(dict[key]!, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &lines)
            }
        case let array as [Any]:
            for (i, element) in array.enumerated() {
                flatten(element, prefix: "\(prefix)[\(i)]", into: &lines)
            }
        default:
            let v = scalar(value)
            guard !v.isEmpty else { return }
            lines.append(prefix.isEmpty ? v : "\(prefix): \(v)")
        }
    }

    private static func scalar(_ value: Any) -> String {
        // CFBoolean must be distinguished from numbers (both bridge to NSNumber).
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return (value as? Bool) == true ? "true" : "false"
        }
        switch value {
        case let s as String:   return s
        case let n as NSNumber: return n.stringValue
        case is NSNull:         return ""
        default:                return "\(value)"
        }
    }
}
