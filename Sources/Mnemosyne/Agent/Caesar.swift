import Foundation

/// Caesar-cipher / ROT-N shift for the `caesar` tool — shift each letter by N positions
/// (default 13 = ROT13), wrapping within the alphabet and preserving case + non-letters.
/// Pure + deterministic → unit-testable. Self-inverse at shift 13.
enum Caesar {
    static func shift(_ text: String, by n: Int) -> String {
        let k = UInt8(((n % 26) + 26) % 26)
        return String(text.map { ch -> Character in
            guard let a = ch.asciiValue else { return ch }
            if a >= 65, a <= 90 { return Character(UnicodeScalar((a - 65 + k) % 26 + 65)) }
            if a >= 97, a <= 122 { return Character(UnicodeScalar((a - 97 + k) % 26 + 97)) }
            return ch
        })
    }
}
