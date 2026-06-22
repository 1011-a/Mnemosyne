import Foundation
import NaturalLanguage

/// READABILITY scoring for the `readability` tool — how dense/approachable a document is,
/// via the Flesch Reading-Ease score (0 = very hard … 100 = very easy). Pairs with
/// `reading_time` and `summarize_item` for triage ("is this a quick skim or a slog?").
///
/// The formula is English-oriented (it counts syllables), so `analyze` first checks the
/// text is Latin/English-dominant and returns nil otherwise — honoring this library's
/// multilingual content rather than reporting a meaningless number for, say, Chinese.
/// Word/sentence segmentation uses Apple's native `NLTokenizer`. The scoring math and the
/// syllable heuristic are pure → unit-testable.
enum ReadabilityAnalyzer {

    /// Flesch Reading-Ease: 206.835 − 1.015·(words/sentences) − 84.6·(syllables/words).
    /// Clamped to 0…100. Returns nil when there aren't enough words/sentences to score.
    static func fleschReadingEase(words: Int, sentences: Int, syllables: Int) -> Double? {
        guard words >= 1, sentences >= 1, syllables >= 1 else { return nil }
        let wordsPerSentence = Double(words) / Double(sentences)
        let syllablesPerWord = Double(syllables) / Double(words)
        let score = 206.835 - 1.015 * wordsPerSentence - 84.6 * syllablesPerWord
        return Swift.min(100, Swift.max(0, score))
    }

    /// A human grade-band for a reading-ease score.
    static func grade(_ score: Double) -> String {
        switch score {
        case 90...:    return "very easy (5th grade)"
        case 70..<90:  return "easy (6th–7th grade)"
        case 50..<70:  return "plain (8th–10th grade)"
        case 30..<50:  return "fairly hard (college)"
        default:       return "very hard (graduate / technical)"
        }
    }

    /// Estimate the syllables in an English word by counting vowel groups, with the
    /// common silent-trailing-e and "-le" adjustments; never returns less than 1 for a
    /// word containing a letter. Pure heuristic → unit-testable.
    static func syllables(in word: String) -> Int {
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
        // Silent trailing 'e' ("make" → 1), but NOT for "-le" endings ("apple" → 2,
        // where the trailing e already carries its own syllable) nor short words ("the").
        if w.hasSuffix("e"), !w.hasSuffix("le"), count > 1 { count -= 1 }
        return Swift.max(1, count)
    }

    struct Result: Sendable { let score: Double; let grade: String; let words: Int; let sentences: Int }

    /// Tokenize, score, and label — or nil if too short or not English/Latin-dominant.
    static func analyze(_ text: String) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        // Guard: the syllable model is English-oriented; skip non-Latin-dominant text.
        if let lang = LanguageDetector.detect(trimmed)?.dominant, !isLatinScript(lang) { return nil }

        let words = tokens(trimmed, unit: .word)
        let sentenceCount = Swift.max(1, tokens(trimmed, unit: .sentence).count)
        guard words.count >= 3 else { return nil }
        let syllableTotal = words.reduce(0) { $0 + syllables(in: $1) }
        guard let score = fleschReadingEase(words: words.count, sentences: sentenceCount,
                                            syllables: syllableTotal) else { return nil }
        return Result(score: score, grade: grade(score), words: words.count, sentences: sentenceCount)
    }

    /// One-line tool reply, or nil when not scorable.
    static func summary(_ text: String) -> String? {
        guard let r = analyze(text) else { return nil }
        return String(format: "reading ease %.0f/100 — %@ (%d words, ~%d sentences)",
                      r.score, r.grade, r.words, r.sentences)
    }

    // MARK: helpers

    private static func isLatinScript(_ code: String) -> Bool {
        ["en", "fr", "de", "es", "it", "pt", "nl", "sv", "no", "da", "fi", "pl",
         "ro", "tr", "id", "ms", "vi", "ca", "cs", "hu"].contains(code)
    }

    private static func tokens(_ text: String, unit: NLTokenUnit) -> [String] {
        let tk = NLTokenizer(unit: unit)
        tk.string = text
        var out: [String] = []
        tk.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }
}
