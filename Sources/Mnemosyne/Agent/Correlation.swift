import Foundation

/// Pearson correlation coefficient between two equal-length number lists for the `correlation` tool.
/// r ranges −1…1: +1 perfect positive, −1 perfect negative, 0 no linear relationship.
/// Pure + deterministic → unit-testable. Pairs with `NumberStats.parse`.
enum Correlation {
    /// Needs ≥2 paired values of equal length; nil if either series has zero variance
    /// (a flat line has no defined correlation). Result is clamped to [−1, 1] for FP safety.
    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var cov = 0.0, vx = 0.0, vy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            cov += dx * dy
            vx += dx * dx
            vy += dy * dy
        }
        guard vx > 0, vy > 0 else { return nil }
        let r = cov / (vx.squareRoot() * vy.squareRoot())
        return Swift.max(-1, Swift.min(1, r))
    }

    /// Plain-English strength label for an r value (sign aware).
    static func describe(_ r: Double) -> String {
        let a = abs(r)
        let strength: String
        switch a {
        case 0.9...:   strength = "very strong"
        case 0.7..<0.9: strength = "strong"
        case 0.5..<0.7: strength = "moderate"
        case 0.3..<0.5: strength = "weak"
        default:        strength = "negligible"
        }
        if a < 0.05 { return "no linear relationship" }
        return "\(strength) \(r < 0 ? "negative" : "positive")"
    }
}
