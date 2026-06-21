import Foundation

/// Word count + minutes-to-read estimate for the `reading_time` tool. Pure +
/// deterministic → unit-testable. Uses a conventional ~220 words-per-minute.
enum ReadingTime {
    static let wordsPerMinute = 220

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// (words, minutes). Any non-empty text reads in at least 1 minute.
    static func estimate(_ text: String, wpm: Int = wordsPerMinute) -> (words: Int, minutes: Int) {
        let w = words(text)
        guard w > 0 else { return (0, 0) }
        let m = Swift.max(1, Int((Double(w) / Double(Swift.max(1, wpm))).rounded()))
        return (w, m)
    }

    static func summary(_ text: String) -> String {
        let e = estimate(text)
        guard e.words > 0 else { return "Empty — nothing to read." }
        return "\(e.words) words · about \(e.minutes) min read"
    }
}
