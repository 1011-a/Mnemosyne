import Foundation

/// Per-character Unicode inspection for the `unicode_info` tool — the code point (U+XXXX) and
/// official Unicode name of each character in some text. Handy for debugging invisible/look-alike
/// characters, emoji, or accents. Pure + deterministic → unit-testable.
enum UnicodeInfo {
    struct Glyph: Equatable {
        let char: String
        let codepoint: String   // "U+0041"
        let name: String        // "LATIN CAPITAL LETTER A"
    }

    /// One row per Unicode scalar (so a 👍🏽 splits into its base + skin-tone modifier), up to
    /// `limit` scalars. Empty text → [].
    static func inspect(_ text: String, limit: Int = 64) -> [Glyph] {
        text.unicodeScalars.prefix(limit).map { s in
            Glyph(char: String(s),
                  codepoint: String(format: "U+%04X", s.value),
                  name: s.properties.name ?? "—")
        }
    }

    /// A compact one-row-per-scalar table for display.
    static func table(_ glyphs: [Glyph]) -> String {
        glyphs.map { "\($0.codepoint)  \($0.char)  \($0.name)" }.joined(separator: "\n")
    }
}
