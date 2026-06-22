import Foundation

/// Greatest common divisor and least common multiple for the `gcd_lcm` tool. Uses the
/// Euclidean algorithm; works on negatives (via absolute value). Pure + deterministic →
/// unit-testable.
enum MathGCD {
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    static func lcm(_ a: Int, _ b: Int) -> Int {
        let g = gcd(a, b)
        return g == 0 ? 0 : abs(a / g * b)   // divide first to limit overflow
    }
}
