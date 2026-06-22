import Foundation

/// Estimates password strength from character-class entropy for the `password_strength` tool —
/// a quick, on-device "how guessable is this?" check (never sends the password anywhere).
/// Entropy ≈ length × log2(pool size), where the pool grows with each character class used.
/// Pure + deterministic → unit-testable.
enum PasswordStrength {
    struct Result {
        let bits: Double      // estimated entropy in bits
        let label: String     // very weak … very strong
        let poolSize: Int     // size of the character pool used
    }

    /// nil for an empty password. Pool: 26 lower + 26 upper + 10 digit + 32 symbol, by class used.
    static func evaluate(_ password: String) -> Result? {
        guard !password.isEmpty else { return nil }
        var pool = 0
        if password.contains(where: { $0.isLowercase && $0.isLetter }) { pool += 26 }
        if password.contains(where: { $0.isUppercase && $0.isLetter }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 32 }
        pool = Swift.max(pool, 1)
        let bits = Double(password.count) * log2(Double(pool))
        return Result(bits: bits, label: label(for: bits), poolSize: pool)
    }

    private static func label(for bits: Double) -> String {
        switch bits {
        case ..<28:   return "very weak"
        case ..<36:   return "weak"
        case ..<60:   return "reasonable"
        case ..<128:  return "strong"
        default:      return "very strong"
        }
    }
}
