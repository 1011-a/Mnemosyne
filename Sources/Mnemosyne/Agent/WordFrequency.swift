import Foundation

/// Counts the most frequent content words in provided text for the `word_frequency` tool — a
/// quick topical fingerprint of any text the agent has in hand (the in-context counterpart to
/// the item-based keyword_extract). Reuses `ExtractiveSummary.tokens` (letters-only, length
/// > 2, stopwords removed). Pure + deterministic → unit-testable.
enum WordFrequency {
    static func top(_ text: String, n: Int = 10) -> [(word: String, count: Int)] {
        var freq: [String: Int] = [:]
        for w in ExtractiveSummary.tokens(text) { freq[w, default: 0] += 1 }
        return freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max(1, n))
            .map { (word: $0.key, count: $0.value) }
    }

    static func summary(_ text: String, n: Int = 10) -> String? {
        let words = top(text, n: n)
        guard !words.isEmpty else { return nil }
        return "Top words: " + words.map { "\($0.word) (\($0.count))" }.joined(separator: ", ") + "."
    }
}
