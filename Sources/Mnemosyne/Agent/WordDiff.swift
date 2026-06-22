import Foundation

/// Word-level difference between two texts for the `word_diff` tool — which words were added
/// vs removed (a multiset difference, case-insensitive). Complements the line-level diff tools.
/// Pure + deterministic → unit-testable.
enum WordDiff {
    static func diff(_ a: String, _ b: String) -> (added: [String], removed: [String]) {
        let af = freq(a), bf = freq(b)
        var added: [String] = [], removed: [String] = []
        for (w, c) in bf {
            let extra = c - (af[w] ?? 0)
            if extra > 0 { added += Array(repeating: w, count: extra) }
        }
        for (w, c) in af {
            let extra = c - (bf[w] ?? 0)
            if extra > 0 { removed += Array(repeating: w, count: extra) }
        }
        return (added.sorted(), removed.sorted())
    }

    static func summary(_ a: String, _ b: String) -> String {
        let d = diff(a, b)
        guard !d.added.isEmpty || !d.removed.isEmpty else { return "No word-level differences." }
        var parts: [String] = []
        if !d.added.isEmpty { parts.append("Added: " + d.added.joined(separator: ", ")) }
        if !d.removed.isEmpty { parts.append("Removed: " + d.removed.joined(separator: ", ")) }
        return parts.joined(separator: "\n")
    }

    private static func freq(_ text: String) -> [String: Int] {
        var f: [String: Int] = [:]
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            f[String(w), default: 0] += 1
        }
        return f
    }
}
