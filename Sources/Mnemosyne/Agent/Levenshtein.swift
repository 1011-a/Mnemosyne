import Foundation

/// Levenshtein edit distance for the `edit_distance` tool — the minimum single-character
/// edits (insert/delete/substitute) to turn one string into another, plus a 0…1 similarity
/// ratio. Character-level, complementing the word-set `text_similarity`. Pure + deterministic
/// (rolling-row DP) → unit-testable.
enum Levenshtein {
    static func distance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        let n = s.count, m = t.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }

    /// 1 − distance / max(len) — 1.0 for identical, 0.0 for completely different (both empty → 1).
    static func ratio(_ a: String, _ b: String) -> Double {
        let maxLen = Swift.max(a.count, b.count)
        return maxLen == 0 ? 1.0 : 1.0 - Double(distance(a, b)) / Double(maxLen)
    }
}
