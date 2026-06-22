import Foundation

/// Reverses text for the `reverse` tool — by characters (grapheme-cluster safe) or by word
/// order. Pure + deterministic → unit-testable.
enum Reverse {
    static func chars(_ s: String) -> String {
        String(s.reversed())
    }

    static func words(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .reversed()
            .joined(separator: " ")
    }
}
