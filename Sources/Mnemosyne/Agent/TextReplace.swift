import Foundation

/// Literal find/replace over text for the `replace_text` tool — transform text the agent has
/// in hand ("replace every X with Y"). Reports how many replacements were made. Pure +
/// deterministic → unit-testable.
enum TextReplace {
    static func replace(_ text: String, find: String, with replacement: String,
                        caseInsensitive: Bool = false) -> (result: String, count: Int) {
        guard !find.isEmpty else { return (text, 0) }
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []

        // Count non-overlapping occurrences before replacing.
        var count = 0
        var searchStart = text.startIndex
        while let r = text.range(of: find, options: options, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = r.upperBound
        }

        let result = text.replacingOccurrences(of: find, with: replacement, options: options)
        return (result, count)
    }
}
