import Foundation

/// Roman-numeral conversion for the `roman_numeral` tool — Arabic ↔ Roman (1–3999), with the
/// direction auto-detected. Pure + deterministic → unit-testable. Parsing is strict: a Roman
/// input must be canonical (round-trips back to itself), so `IIII` is rejected.
enum Roman {
    private static let table: [(value: Int, symbol: String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
        (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
        (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]

    static func toRoman(_ n: Int) -> String? {
        guard n >= 1, n <= 3999 else { return nil }
        var remaining = n
        var out = ""
        for (value, symbol) in table {
            while remaining >= value { out += symbol; remaining -= value }
        }
        return out
    }

    static func fromRoman(_ s: String) -> Int? {
        let upper = s.uppercased()
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0, prev = 0
        for ch in upper.reversed() {
            guard let v = values[ch] else { return nil }
            if v < prev { total -= v } else { total += v; prev = v }
        }
        // Strict: only accept canonical numerals (so "IIII" → nil).
        guard total >= 1, total <= 3999, toRoman(total) == upper else { return nil }
        return total
    }

    /// Auto-detect: a number → Roman, a Roman numeral → its Arabic value. Nil if neither.
    static func convert(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return toRoman(n) }
        if let n = fromRoman(t) { return String(n) }
        return nil
    }
}
