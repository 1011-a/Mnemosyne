import Foundation

/// An offline EXTRACTIVE summarizer for the `quick_summary` tool — picks a document's most
/// salient existing sentences (by word-frequency scoring), no AI model required. Instant and
/// works with no API key, complementing the LLM-based `summarize_item` (which paraphrases).
/// Pure + deterministic → unit-testable.
enum ExtractiveSummary {
    /// Common words that carry little topical signal — excluded from scoring.
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her",
        "was", "one", "our", "out", "has", "his", "how", "its", "may", "new", "now", "old",
        "see", "two", "way", "who", "did", "get", "him", "she", "too", "use", "that", "this",
        "with", "have", "from", "they", "will", "your", "what", "when", "were", "been", "than",
        "then", "them", "into", "more", "some", "such", "only", "over", "also", "back", "after",
        "would", "there", "their", "which", "about", "could", "these", "those", "where",
    ]

    /// Split text into sentences on terminal punctuation (`.`, `!`, `?`), keeping `...` together.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < chars.count, chars[j] == "." || chars[j] == "!" || chars[j] == "?" {
                    current.append(chars[j]); j += 1
                }
                if j >= chars.count || chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" {
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { result.append(s) }
                    current = ""
                }
                i = j
                continue
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Content tokens: lowercased, letters only, length > 2, excluding stopwords.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }

    static func wordFrequency(_ text: String) -> [String: Int] {
        var freq: [String: Int] = [:]
        for w in tokens(text) { freq[w, default: 0] += 1 }
        return freq
    }

    /// Return the `maxSentences` most salient sentences, joined in original document order.
    /// Short documents (≤ maxSentences) are returned whole; empty input → nil.
    static func summarize(_ text: String, maxSentences: Int = 3) -> String? {
        let sents = sentences(text)
        guard !sents.isEmpty else { return nil }
        guard sents.count > maxSentences else { return sents.joined(separator: " ") }

        let freq = wordFrequency(text)
        let scored = sents.enumerated().map { idx, s -> (idx: Int, score: Double) in
            let ws = tokens(s)
            guard !ws.isEmpty else { return (idx, 0) }
            let total = ws.reduce(0) { $0 + (freq[$1] ?? 0) }
            return (idx, Double(total) / Double(ws.count))   // average salience (length-normalized)
        }
        let top = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.idx < $1.idx }
            .prefix(maxSentences)
            .sorted { $0.idx < $1.idx }
        return top.map { sents[$0.idx] }.joined(separator: " ")
    }
}
