import Foundation

/// Computes readability + length metrics for the `text_stats` tool — "how long is this?",
/// "how hard is it to read?". Words, sentences, estimated reading time, and the classic
/// Flesch Reading Ease score (with a plain-language band). Pure + deterministic →
/// unit-testable.
enum TextStats {
    struct Stats: Equatable {
        let words: Int
        let sentences: Int
        let syllables: Int
        let readingMinutes: Double      // at ~200 wpm
        let avgSentenceLength: Double
        let fleschReadingEase: Double
    }

    static func analyze(_ text: String) -> Stats? {
        let words = wordTokens(text)
        guard !words.isEmpty else { return nil }
        let wordCount = words.count
        let sentenceCount = max(1, sentenceCount(text))
        let syllableCount = words.reduce(0) { $0 + syllables($1) }

        let asl = Double(wordCount) / Double(sentenceCount)
        let asw = Double(syllableCount) / Double(wordCount)
        let flesch = 206.835 - 1.015 * asl - 84.6 * asw

        return Stats(words: wordCount,
                     sentences: sentenceCount,
                     syllables: syllableCount,
                     readingMinutes: Double(wordCount) / 200.0,
                     avgSentenceLength: asl,
                     fleschReadingEase: flesch)
    }

    /// Words = whitespace-separated tokens containing at least one letter or digit.
    static func wordTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}…—–-")) }
            .filter { token in token.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Sentences ≈ runs of terminal punctuation (`.`, `!`, `?`); `...` counts once.
    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var prevTerminator = false
        for ch in text {
            let isTerm = ch == "." || ch == "!" || ch == "?"
            if isTerm && !prevTerminator { count += 1 }
            prevTerminator = isTerm
        }
        return count
    }

    /// Heuristic syllable count: vowel groups, minus a silent trailing `e` (but not `le`).
    static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter { $0.isLetter }
        guard !w.isEmpty else { return 0 }
        let vowels = Set("aeiouy")
        var count = 0
        var prevVowel = false
        for ch in w {
            let isVowel = vowels.contains(ch)
            if isVowel && !prevVowel { count += 1 }
            prevVowel = isVowel
        }
        if w.hasSuffix("e") && !w.hasSuffix("le") && count > 1 { count -= 1 }
        return max(1, count)
    }

    /// A plain-language label for a Flesch Reading Ease score.
    static func readingEaseBand(_ score: Double) -> String {
        switch score {
        case 90...: return "very easy"
        case 70..<90: return "easy"
        case 60..<70: return "standard"
        case 30..<60: return "difficult"
        default: return "very difficult"
        }
    }

    static func report(_ text: String) -> String? {
        guard let s = analyze(text) else { return nil }
        let mins = s.readingMinutes < 1 ? "<1 min" : "~\(Int(s.readingMinutes.rounded())) min"
        let ease = String(format: "%.0f", s.fleschReadingEase)
        let asl = String(format: "%.1f", s.avgSentenceLength)
        return "\(s.words) words, \(s.sentences) sentence(s), \(mins) read. "
            + "Avg sentence length \(asl) words. "
            + "Reading ease \(ease) (\(readingEaseBand(s.fleschReadingEase)))."
    }
}
