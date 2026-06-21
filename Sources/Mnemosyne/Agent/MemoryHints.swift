import Foundation

/// Heuristics that spot when a user message states a DURABLE preference or fact
/// worth pinning to long-term memory ("I always…", "my name is…", "please remember…").
/// Pure + deterministic → unit-testable; drives a gentle "Remember this?" chip.
enum MemoryHints {
    /// Phrases that signal a lasting fact/preference (English + common Chinese).
    static let cues = [
        "i always", "i never", "i prefer", "i usually", "i tend to", "i like to",
        "my name is", "call me", "i'm called", "i am called",
        "my favourite", "my favorite", "i live in", "i work at", "i work as",
        "i'm a ", "i am a ", "remember that", "remember i", "please remember",
        "for future reference", "note that i",
        "我叫", "我喜欢", "我的名字", "请记住", "记住我", "以后记住",
    ]

    /// The candidate fact to offer pinning, or nil when the message isn't a durable
    /// statement (too short/long, a question, or no cue phrase).
    static func durableFactCandidate(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 5, t.count <= 240, !t.hasSuffix("?") else { return nil }
        let low = t.lowercased()
        // Questions aren't durable facts even without a trailing '?'.
        for q in ["what ", "how ", "why ", "who ", "when ", "where ", "do you", "can you", "could you"] {
            if low.hasPrefix(q) { return nil }
        }
        guard cues.contains(where: { low.contains($0) }) else { return nil }
        return t
    }
}
