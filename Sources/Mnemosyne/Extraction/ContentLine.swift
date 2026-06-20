import Foundation

/// Shared line parsing for the RFC 6350 (vCard) / RFC 5545 (iCalendar) text
/// formats: physical-line unfolding, property name/value splitting, and value
/// unescaping. Used by both `VCardExtractor` and `ICalExtractor`.
enum ContentLine {
    /// Unfold folded lines — a continuation begins with a space or tab, and is
    /// joined to the previous line with the leading whitespace removed.
    static func unfold(_ raw: String) -> [String] {
        let physical = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        for line in physical {
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += line.drop(while: { $0 == " " || $0 == "\t" })
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Split a content line into (UPPERCASE property name, unescaped value),
    /// dropping any `;param=…` segments on the name side. Returns nil for blank
    /// values or lines without a colon.
    static func property(_ line: String) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon]
        let value = unescape(String(line[line.index(after: colon)...]))
        let name = String(head.split(separator: ";").first ?? "").uppercased()
        guard !name.isEmpty, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (name, value)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespaces)
    }
}
