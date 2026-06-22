import Foundation

/// Vigenère cipher (keyword-based polyalphabetic shift) for the `vigenere` tool — a stronger
/// classic cipher than Caesar: each letter is shifted by the next letter of a repeating keyword.
/// Case is preserved; non-letters pass through and do NOT consume a key letter. Pure +
/// deterministic → unit-testable. Pairs with [[Caesar]].
enum VigenereCipher {
    /// Encode or decode `text` with `key`. Returns nil if the key has no letters (nothing to
    /// shift by). `decode = true` inverts the shift.
    static func transform(_ text: String, key: String, decode: Bool) -> String? {
        let keyLetters = key.lowercased().filter { $0.isLetter && $0.isASCII }
        guard !keyLetters.isEmpty else { return nil }
        let shifts = keyLetters.map { Int($0.asciiValue! - Character("a").asciiValue!) }
        var ki = 0
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            guard ch.isLetter && ch.isASCII, let ascii = ch.asciiValue else {
                out.append(ch)   // non-letters pass through, key position unchanged
                continue
            }
            let base: UInt8 = ch.isUppercase ? 65 : 97
            let offset = Int(ascii - base)
            let s = shifts[ki % shifts.count]
            let shifted = decode ? (offset - s + 26) % 26 : (offset + s) % 26
            out.append(Character(UnicodeScalar(base + UInt8(shifted))))
            ki += 1
        }
        return out
    }
}
