import Foundation

/// Number-base conversion for the `number_bases` tool — show an integer in decimal, hex,
/// binary, and octal at once. Auto-detects the input base from a `0x`/`0b`/`0o` prefix
/// (decimal otherwise). Pure + deterministic → unit-testable.
enum NumberBases {
    /// Parse an integer written in decimal or with a `0x`/`0b`/`0o` prefix; nil if invalid.
    static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        if t.hasPrefix("0b") { return Int(t.dropFirst(2), radix: 2) }
        if t.hasPrefix("0o") { return Int(t.dropFirst(2), radix: 8) }
        return Int(t)
    }

    static func describe(_ s: String) -> String? {
        guard let n = parse(s) else { return nil }
        return "decimal \(n), hex \(prefixed(n, "0x", 16)), "
            + "binary \(prefixed(n, "0b", 2)), octal \(prefixed(n, "0o", 8))"
    }

    /// Render `n` in `radix` with `prefix`, keeping a leading minus for negatives.
    private static func prefixed(_ n: Int, _ prefix: String, _ radix: Int) -> String {
        n < 0 ? "-\(prefix)\(String(-n, radix: radix))" : "\(prefix)\(String(n, radix: radix))"
    }
}
