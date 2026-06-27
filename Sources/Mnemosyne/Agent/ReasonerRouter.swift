import Foundation

/// Decides when a query is worth routing to DeepSeek's `deepseek-v4-pro` (R1) instead of
/// `deepseek-v4-flash` — R1 spends extra tokens on an explicit chain-of-thought, which pays off for
/// analytical/multi-step questions but is wasteful for quick lookups. DeepSeek-only: the reasoner
/// model has no OpenAI equivalent. Pure + deterministic → unit-testable. Pairs with the
/// `deep_reason` tool and [[DeepSeekReasoning]].
enum ReasonerRouter {
    /// Single-word signals that a question needs reasoning (matched on whole words).
    private static let wordSignals: Set<String> = [
        "why", "prove", "derive", "analyze", "analyse", "calculate", "compute", "debug",
        "optimize", "optimise", "reasoning", "logic", "puzzle", "estimate", "compare", "versus",
    ]
    /// Multi-word signals (matched as substrings).
    private static let phraseSignals = [
        "step by step", "step-by-step", "trade-off", "tradeoff", "pros and cons",
        "explain how", "explain why", "how would", "work out", "figure out", "walk me through",
    ]

    /// True when the query looks analytical enough to benefit from the reasoner: any reasoning
    /// keyword/phrase, or a long (40+ word) prompt. Quick factual lookups stay on deepseek-v4-flash.
    static func shouldUseReasoner(_ query: String) -> Bool {
        let q = query.lowercased()
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let words = Set(q.split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: wordSignals) { return true }
        if phraseSignals.contains(where: { q.contains($0) }) { return true }
        return q.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count > 40
    }

    /// A short human-readable rationale for the routing decision (for the activity trace).
    static func rationale(_ query: String) -> String {
        shouldUseReasoner(query)
            ? "Analytical/multi-step question — routing to deepseek-v4-pro."
            : "Straightforward question — deepseek-v4-flash is sufficient."
    }
}
