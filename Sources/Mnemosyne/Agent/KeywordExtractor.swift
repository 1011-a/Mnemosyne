import Foundation

/// Surfaces a document's most salient terms by frequency (stopwords removed), for
/// the `keyword_extract` tool. Pure + deterministic → unit-testable. Not a full
/// TF-IDF (no corpus here) but enough to give the agent a quick topical fingerprint.
enum KeywordExtractor {
    /// Common English function words to drop (kept small + focused on noise).
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "with", "that", "this", "these",
        "those", "have", "has", "had", "not", "but", "you", "your", "from", "into",
        "they", "them", "their", "there", "here", "what", "when", "where", "which",
        "who", "whom", "how", "why", "all", "any", "can", "will", "would", "could",
        "should", "about", "over", "under", "then", "than", "such", "some", "more",
        "most", "other", "also", "been", "being", "its", "our", "his", "her", "she",
        "him", "out", "off", "per", "via", "use", "used", "using", "one", "two",
    ]

    /// Top terms by frequency. Tokens are runs of letters/digits with length ≥ 3
    /// (so short noise and pure numbers are skipped); ties broken alphabetically.
    static func topTerms(_ text: String, limit: Int = 12) -> [(term: String, count: Int)] {
        var counts: [String: Int] = [:]
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 3, !stopwords.contains(current),
                  current.contains(where: { $0.isLetter }) else { return }
            counts[current, default: 0] += 1
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return counts.map { (term: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.term < $1.term }
            .prefix(limit).map { $0 }
    }

    /// Dominant themes across many documents by DOCUMENT FREQUENCY: how many docs
    /// mention each salient term (counted once per doc). Only terms in ≥2 docs, to
    /// surface real themes over one-off words. Pure → unit-testable.
    static func libraryThemes(docs: [String], top: Int = 15, perDoc: Int = 6) -> [(term: String, count: Int)] {
        var df: [String: Int] = [:]
        for doc in docs {
            for t in Set(topTerms(doc, limit: perDoc).map(\.term)) { df[t, default: 0] += 1 }
        }
        return df.filter { $0.value >= 2 }.map { (term: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.term < $1.term }
            .prefix(top).map { $0 }
    }

    /// "term (count), term (count), …" — or a friendly note when nothing salient.
    static func summary(_ text: String, limit: Int = 12) -> String {
        let terms = topTerms(text, limit: limit)
        guard !terms.isEmpty else { return "No salient terms found." }
        return terms.map { "\($0.term) (\($0.count))" }.joined(separator: ", ")
    }
}
