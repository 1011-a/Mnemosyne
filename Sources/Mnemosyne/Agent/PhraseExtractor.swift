import Foundation

/// Extracts multi-word KEY PHRASES (collocations) for the `key_phrases` tool — "machine
/// learning", "quarterly report" — a far better topical fingerprint than single words.
/// Counts bigrams/trigrams whose every token is a content word (no stopwords, length ≥ 3),
/// keeps those that recur. Pure + deterministic → unit-testable. Reuses
/// `ExtractiveSummary.stopwords`.
enum PhraseExtractor {
    /// Ordered lowercased word tokens (letters only, length ≥ 2 so they can anchor a phrase).
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 2 }
    }

    /// All n-grams whose tokens are each a content word (length ≥ 3, not a stopword).
    static func grams(_ words: [String], n: Int) -> [String] {
        guard words.count >= n else { return [] }
        var out: [String] = []
        for i in 0...(words.count - n) {
            let slice = Array(words[i..<i + n])
            if slice.contains(where: { $0.count < 3 || ExtractiveSummary.stopwords.contains($0) }) { continue }
            out.append(slice.joined(separator: " "))
        }
        return out
    }

    /// Top recurring phrases (count ≥ 2), ranked by frequency then alphabetically.
    static func extract(_ text: String, top: Int = 10) -> [(phrase: String, count: Int)] {
        let w = words(text)
        var freq: [String: Int] = [:]
        for n in [2, 3] {
            for g in grams(w, n: n) { freq[g, default: 0] += 1 }
        }
        return freq.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(top)
            .map { (phrase: $0.key, count: $0.value) }
    }

    static func summary(_ text: String, top: Int = 10) -> String? {
        let phrases = extract(text, top: top)
        guard !phrases.isEmpty else { return nil }
        return "Key phrases: " + phrases.map { "\($0.phrase) (\($0.count))" }.joined(separator: ", ") + "."
    }
}
