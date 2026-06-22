import Foundation

/// Letter-frequency analysis for the `char_frequency` tool — count how often each letter appears
/// (case-insensitive), the classic first step in breaking a substitution/Caesar/Vigenère cipher.
/// Only A–Z letters are counted; everything else is ignored. Pure + deterministic → unit-testable.
/// Pairs with [[Caesar]] / [[VigenereCipher]].
enum CharFrequency {
    /// (letter, count, percent-of-letters) sorted by count descending, ties broken alphabetically.
    /// Returns an empty array when the text has no letters.
    static func analyze(_ text: String) -> [(letter: Character, count: Int, percent: Double)] {
        var counts: [Character: Int] = [:]
        for ch in text.lowercased() where ch.isLetter && ch.isASCII {
            counts[ch, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts
            .map { (letter: $0.key, count: $0.value, percent: Double($0.value) / Double(total) * 100) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.letter < $1.letter }
    }

    /// A compact text table of the top `limit` letters (default all), one per line.
    static func table(_ rows: [(letter: Character, count: Int, percent: Double)], limit: Int = 26) -> String {
        rows.prefix(limit).map { r in
            "\(String(r.letter).uppercased())  \(r.count)  (\(String(format: "%.1f", r.percent))%)"
        }.joined(separator: "\n")
    }
}
