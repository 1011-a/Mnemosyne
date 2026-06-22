import Foundation
import NaturalLanguage

/// On-device SENTIMENT analysis for the `sentiment` tool — gauges the emotional tone of
/// a document (e.g. "how positive is this review / journal entry / feedback note").
/// Uses Apple's native `NLTagger(.sentimentScore)` — zero-dependency, offline, private
/// (same NaturalLanguage family as the embedder + entity extractor). The raw score runs
/// −1 (negative) … +1 (positive); multi-paragraph text is averaged. Deterministic for a
/// given input → unit-testable.
enum SentimentAnalyzer {

    /// Mean sentiment across the document's paragraphs, or nil for empty input.
    static func score(_ text: String) -> Double? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        var sum = 0.0, n = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .paragraph,
                             scheme: .sentimentScore, options: []) { tag, _ in
            if let raw = tag?.rawValue, let v = Double(raw) { sum += v; n += 1 }
            return true
        }
        guard n > 0 else { return nil }
        return sum / Double(n)
    }

    /// A human label for a score on the −1…+1 scale.
    static func label(_ score: Double) -> String {
        switch score {
        case ..<(-0.6):  return "very negative"
        case ..<(-0.15): return "negative"
        case ..<(0.15):  return "neutral"
        case ..<(0.6):   return "positive"
        default:         return "very positive"
        }
    }

    /// A one-line tool reply ("positive (score +0.42…)"), or nil when there's no text.
    static func summary(_ text: String) -> String? {
        guard let s = score(text) else { return nil }
        return String(format: "%@ (score %+.2f on a −1 negative … +1 positive scale)", label(s), s)
    }
}
