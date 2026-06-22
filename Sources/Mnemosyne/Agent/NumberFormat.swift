import Foundation

/// Adds thousands separators to a number for the `number_format` tool — '1234567' →
/// '1,234,567'. Preserves sign and any decimal part; existing commas are re-grouped. Pure +
/// deterministic → unit-testable.
enum NumberFormat {
    static func grouped(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard Double(s) != nil else { return nil }   // validate numeric

        var sign = ""
        var body = s
        if body.hasPrefix("-") { sign = "-"; body.removeFirst() }
        else if body.hasPrefix("+") { body.removeFirst() }

        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let decPart = parts.count > 1 ? "." + parts[1] : ""

        var grouped = ""
        var count = 0
        for ch in intPart.reversed() {
            if count > 0, count % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
            count += 1
        }
        return sign + String(grouped.reversed()) + decPart
    }
}
