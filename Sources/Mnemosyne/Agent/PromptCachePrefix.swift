import Foundation

/// Helpers to keep the agent's leading prompt prefix BYTE-STABLE across requests, which is what
/// lets DeepSeek's context cache hit (`prompt_cache_hit_tokens`). The static system prompt is
/// already stable; the pinned-facts block is the risk — if the DB returns facts in a different
/// order between sessions, the prefix changes and the cache misses. Sorting + de-duping makes the
/// block deterministic. Pure → unit-testable. Pairs with [[DeepSeekUsage]].
enum PromptCachePrefix {
    /// A deterministic "- fact" bullet block from pinned facts: trimmed, blank-dropped, de-duped
    /// (case-insensitively), and sorted so the same set of facts always serializes identically.
    /// Empty input → empty string.
    static func stableFactsBlock(_ facts: [String]) -> String {
        var seen = Set<String>()
        let lines = facts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted()
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Size (in characters) of the cacheable prefix: the leading run of `system` messages, up to
    /// the first non-system message. A bigger stable prefix = more tokens served from cache.
    static func cacheablePrefixChars(_ messages: [[String: Any]]) -> Int {
        var total = 0
        for m in messages {
            guard (m["role"] as? String) == "system" else { break }
            total += (m["content"] as? String)?.count ?? 0
        }
        return total
    }
}
