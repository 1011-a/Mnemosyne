import Foundation

/// Converts an integer between arbitrary numeric bases (2–36) for the `convert_base` tool —
/// more general than `number_bases`. Pure + deterministic → unit-testable.
enum BaseConvert {
    /// Parse `value` in base `from`, render in base `to`. Nil if a base is out of 2…36 or the
    /// value has invalid digits for `from`.
    static func convert(_ value: String, from: Int, to: Int) -> String? {
        guard (2...36).contains(from), (2...36).contains(to) else { return nil }
        var body = value.trimmingCharacters(in: .whitespaces)
        var sign = ""
        if body.hasPrefix("-") { sign = "-"; body.removeFirst() }
        guard !body.isEmpty, let n = Int(body, radix: from) else { return nil }
        return sign + String(n, radix: to)
    }
}
