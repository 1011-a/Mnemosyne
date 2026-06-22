import Foundation

/// Title-cases a headline for the `headline_case` tool — capitalizes major words but keeps
/// short articles/conjunctions/prepositions lowercase (unless first or last). Closer to
/// AP/Chicago style than a blanket `.capitalized`. Pure + deterministic → unit-testable.
enum HeadlineCase {
    static let minorWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
        "at", "by", "in", "of", "on", "to", "up", "as", "per", "via",
    ]

    static func titleize(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return "" }
        let last = words.count - 1
        return words.enumerated().map { i, w in
            let lower = w.lowercased()
            if i == 0 || i == last || !minorWords.contains(lower) { return capitalize(w) }
            return lower
        }.joined(separator: " ")
    }

    private static func capitalize(_ w: String) -> String {
        w.prefix(1).uppercased() + w.dropFirst().lowercased()
    }
}
