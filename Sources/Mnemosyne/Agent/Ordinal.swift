import Foundation

/// Formats a number as an ordinal for the `ordinal` tool — 1 → "1st", 23 → "23rd", 111 →
/// "111th". Handles the 11/12/13 exceptions. Pure + deterministic → unit-testable.
enum Ordinal {
    static func suffix(_ n: Int) -> String {
        let m = abs(n) % 100
        if (11...13).contains(m) { return "th" }
        switch abs(n) % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    static func format(_ n: Int) -> String { "\(n)\(suffix(n))" }
}
