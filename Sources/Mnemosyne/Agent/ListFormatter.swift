import Foundation

/// Reformats a list of items for the `format_list` tool — numbered, bulleted, comma-joined, or
/// an Oxford-comma sentence. Strips any existing bullet/number/checkbox first. Pure +
/// deterministic → unit-testable.
enum ListFormatter {
    static func format(_ text: String, style: String) -> String? {
        let items = text.components(separatedBy: "\n")
            .map { stripMarker($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }

        switch style.lowercased() {
        case "numbered":
            return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case "bullet", "bulleted":
            return items.map { "- \($0)" }.joined(separator: "\n")
        case "comma":
            return items.joined(separator: ", ")
        case "and", "sentence":
            return oxford(items)
        default:
            return nil
        }
    }

    /// "a", "a and b", or "a, b, and c".
    private static func oxford(_ items: [String]) -> String {
        switch items.count {
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private static func stripMarker(_ s: String) -> String {
        var t = s
        for p in [#"^[-*+]\s+"#, #"^\d+[.)]\s+"#, #"^\[.\]\s*"#] {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
