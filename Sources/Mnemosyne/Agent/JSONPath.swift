import Foundation

/// Extracts a value from a JSON document by a dot/bracket path for the `json_value` tool —
/// `address.city`, `items[0].id`, `[2]`. Lets the agent pull a specific field out of a
/// config/export, complementing `JSONInspector` (which shows the shape). Pure +
/// deterministic → unit-testable.
enum JSONPath {
    enum Component: Equatable {
        case key(String)
        case index(Int)
    }

    enum Outcome: Equatable {
        case badJSON
        case badPath
        case notFound
        case found(String)
    }

    /// Parse `a.b[0].c` into components, or nil if malformed (unbalanced/empty/non-integer index).
    static func parse(_ path: String) -> [Component]? {
        let s = path.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var comps: [Component] = []
        var current = ""
        func flushKey() { if !current.isEmpty { comps.append(.key(current)); current = "" } }

        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            switch c {
            case ".":
                flushKey()
            case "[":
                flushKey()
                guard let close = s[idx...].firstIndex(of: "]") else { return nil }
                let inner = String(s[s.index(after: idx)..<close]).trimmingCharacters(in: .whitespaces)
                guard let n = Int(inner) else { return nil }
                comps.append(.index(n))
                idx = close
            case "]":
                return nil   // unbalanced
            default:
                current.append(c)
            }
            idx = s.index(after: idx)
        }
        flushKey()
        return comps.isEmpty ? nil : comps
    }

    /// Walk a parsed JSON value along the path; nil if any step is missing or mistyped.
    static func lookup(root: Any, path: [Component]) -> Any? {
        var cur: Any? = root
        for comp in path {
            switch comp {
            case .key(let k):
                guard let dict = cur as? [String: Any], let v = dict[k] else { return nil }
                cur = v
            case .index(let n):
                guard let arr = cur as? [Any], arr.indices.contains(n) else { return nil }
                cur = arr[n]
            }
        }
        return cur
    }

    /// Render a looked-up value: scalars literally, containers as compact (truncated) JSON.
    static func render(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        }
        if let s = v as? String { return s }
        if v is [Any] || v is [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str.count > 600 ? String(str.prefix(600)) + "…" : str
            }
            return JSONInspector.summaryType(v)
        }
        return "\(v)"
    }

    static func query(_ text: String, path: String) -> Outcome {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return .badJSON }
        guard let comps = parse(path) else { return .badPath }
        guard let v = lookup(root: root, path: comps) else { return .notFound }
        return .found(render(v))
    }
}
