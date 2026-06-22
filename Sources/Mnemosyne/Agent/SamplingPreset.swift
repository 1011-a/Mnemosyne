import Foundation

/// DeepSeek's officially-recommended sampling temperatures per use case (from DeepSeek's API
/// docs) — the right temperature differs a lot by task: deterministic for code/math, hotter for
/// creative writing. Encoding the table here means each call site picks the documented value
/// instead of a guessed constant. Pure + deterministic → unit-testable.
enum SamplingPreset {
    enum TaskKind: Equatable {
        case codingMath        // 0.0 — code, math, exact answers
        case dataAnalysis      // 1.0 — data cleaning / analysis
        case conversation      // 1.3 — general chat
        case translation       // 1.3 — translation
        case creative          // 1.5 — creative writing / poetry
    }

    /// DeepSeek's recommended temperature for a task kind.
    static func temperature(for kind: TaskKind) -> Double {
        switch kind {
        case .codingMath:   return 0.0
        case .dataAnalysis: return 1.0
        case .conversation: return 1.3
        case .translation:  return 1.3
        case .creative:     return 1.5
        }
    }

    /// Best-effort classification of a free-text request into a task kind, so a caller can pick
    /// the matching temperature. Falls back to `.conversation`.
    static func classify(_ query: String) -> TaskKind {
        let q = query.lowercased()
        let words = Set(q.split { !$0.isLetter }.map(String.init))

        if !words.isDisjoint(with: ["translate", "translation"]) { return .translation }
        if !words.isDisjoint(with: ["poem", "poetry", "story", "haiku", "song", "lyrics", "fiction"])
            || q.contains("write a") { return .creative }
        if !words.isDisjoint(with: ["code", "function", "bug", "compile", "regex", "refactor",
                                    "debug", "swift", "python", "javascript", "sql"])
            || !words.isDisjoint(with: ["calculate", "solve", "equation", "integral", "derivative",
                                        "factorial", "probability"]) { return .codingMath }
        if !words.isDisjoint(with: ["analyze", "analyse", "dataset", "data", "summarize", "summarise",
                                    "csv", "statistics", "correlation"]) { return .dataAnalysis }
        return .conversation
    }

    /// Convenience: the recommended temperature for a free-text request in one step.
    static func temperature(forQuery query: String) -> Double {
        temperature(for: classify(query))
    }
}
