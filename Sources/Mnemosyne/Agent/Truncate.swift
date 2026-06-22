import Foundation

/// Truncates text to a length for the `truncate` tool — by characters or by words, appending
/// an ellipsis only when something was cut. Pure + deterministic → unit-testable.
enum Truncate {
    static func toChars(_ s: String, _ max: Int, ellipsis: String = "…") -> String {
        guard max > 0, s.count > max else { return s }
        return String(s.prefix(max)).trimmingCharacters(in: .whitespaces) + ellipsis
    }

    static func toWords(_ s: String, _ max: Int, ellipsis: String = "…") -> String {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard max > 0, words.count > max else { return s }
        return words.prefix(max).joined(separator: " ") + ellipsis
    }
}
