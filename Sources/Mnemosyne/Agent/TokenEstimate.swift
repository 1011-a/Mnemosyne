import Foundation

/// Script-aware token estimator for budgeting against DeepSeek's context window. The old
/// chars/4 rule badly under-counts CJK text — DeepSeek's BPE tokenizer emits roughly 1–2 tokens
/// per Chinese/Japanese/Korean character, vs ~4 Latin characters per token — so a document of
/// Chinese audio transcripts could blow the window while chars/4 says it's fine. Counting CJK
/// separately gives a realistic (slightly conservative) estimate. Pure + deterministic →
/// unit-testable. Used by `ContextManager`.
enum TokenEstimate {
    /// Estimated token count: ~1.5 tokens per CJK character + ~1 token per 4 other characters.
    /// Always ≥ 1 for non-empty input.
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0, other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        let tokens = Double(cjk) * 1.5 + Double(other) / 4.0
        return Swift.max(1, Int(tokens.rounded(.up)))
    }

    /// True for Han ideographs, kana, Hangul, and CJK symbols/punctuation — the scripts that
    /// tokenize far denser than Latin.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F,   // CJK symbols & punctuation
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF:   // Halfwidth/Fullwidth forms
            return true
        default:
            return false
        }
    }
}
