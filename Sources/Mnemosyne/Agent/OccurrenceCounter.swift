import Foundation

/// Counts how many times a needle appears in some text for the `count_occurrences` tool —
/// "how often does X show up in this passage?". Supports case-insensitive (default) and
/// whole-word matching. Overlapping matches are NOT double-counted (scan advances past each hit).
/// Pure + deterministic → unit-testable.
enum OccurrenceCounter {
    /// nil when `needle` is empty. `wholeWord` requires a non-letter/digit boundary (or string
    /// edge) on both sides of each match.
    static func count(in text: String, needle: String,
                      caseSensitive: Bool = false, wholeWord: Bool = false) -> Int? {
        guard !needle.isEmpty else { return nil }
        let hay = Array(caseSensitive ? text : text.lowercased())
        let pat = Array(caseSensitive ? needle : needle.lowercased())
        guard hay.count >= pat.count else { return 0 }
        var count = 0, i = 0
        while i <= hay.count - pat.count {
            if Array(hay[i..<i + pat.count]) == pat,
               !wholeWord || isWordBoundary(hay, start: i, length: pat.count) {
                count += 1
                i += pat.count   // non-overlapping
            } else {
                i += 1
            }
        }
        return count
    }

    /// True when the chars just before `start` and just after the match are word boundaries
    /// (string edge or a non-alphanumeric character).
    private static func isWordBoundary(_ hay: [Character], start: Int, length: Int) -> Bool {
        let before = start - 1
        let after = start + length
        let leftOK = before < 0 || !(hay[before].isLetter || hay[before].isNumber)
        let rightOK = after >= hay.count || !(hay[after].isLetter || hay[after].isNumber)
        return leftOK && rightOK
    }
}
