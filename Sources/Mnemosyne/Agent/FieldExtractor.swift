import Foundation

/// Prompt + result helpers for the `extract_fields` tool, which pulls named structured fields out
/// of free text using DeepSeek's force-JSON path (`DeepSeekClient.completeJSON`). Keeping the
/// prompt assembly and the JSON→table formatting pure makes them unit-testable; only the live
/// model call stays in the handler. Pairs with [[JSONExtract]].
enum FieldExtractor {
    /// The `prior` chat messages for `completeJSON`: a strict system instruction plus the field
    /// list and source text. The model is told to return a JSON object keyed by exactly these
    /// fields, with null for anything missing.
    static func messages(text: String, fields: [String]) -> [[String: Any]] {
        let list = fields.joined(separator: ", ")
        return [
            ["role": "system",
             "content": "You extract structured data. Return ONLY a JSON object whose keys are EXACTLY these fields: \(list). Use null when a field is not present in the text. No prose, no extra keys."],
            ["role": "user",
             "content": "Fields: \(list)\n\nText:\n\(text)"],
        ]
    }

    /// Render the extracted JSON object as an aligned "field: value" table, one row per requested
    /// field (so the output order is stable and missing fields are shown as "—"). nil when the
    /// string isn't a JSON object.
    static func format(json: String, fields: [String]) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        let width = fields.map(\.count).max() ?? 0
        return fields.map { field in
            let label = field.padding(toLength: width, withPad: " ", startingAt: 0)
            return "\(label)  \(render(dict[field]))"
        }.joined(separator: "\n")
    }

    /// Human-readable rendering of a JSON value; missing/null → "—", containers → compact JSON.
    private static func render(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "—"
        case let s as String: return s.isEmpty ? "—" : s
        case let n as NSNumber:
            // Distinguish JSON booleans (CFBoolean) from numbers — NSNumber→Bool bridging is
            // unreliable for ints, so check the underlying CF type.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default:
            if let v = value,
               let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]),
               let s = String(data: d, encoding: .utf8) {
                return s
            }
            return "—"
        }
    }
}
