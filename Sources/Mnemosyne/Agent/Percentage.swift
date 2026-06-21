import Foundation

/// Everyday percentage math for the `percentage` tool — the three common questions: "what is
/// X% of Y", "X is what percent of Y", and "percent change from A to B". Pure + deterministic
/// → unit-testable. Division-by-zero cases return nil.
enum Percentage {
    /// `pct`% of `value`.
    static func of(_ pct: Double, _ value: Double) -> Double { pct / 100 * value }

    /// `part` is what percent of `whole`; nil when whole is 0.
    static func whatPercent(_ part: Double, of whole: Double) -> Double? {
        whole == 0 ? nil : part / whole * 100
    }

    /// Percent change from `from` to `to`; nil when from is 0.
    static func change(from: Double, to: Double) -> Double? {
        from == 0 ? nil : (to - from) / abs(from) * 100
    }

    /// Whole numbers as ints, else up to 2 decimals (trailing zeros trimmed).
    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
