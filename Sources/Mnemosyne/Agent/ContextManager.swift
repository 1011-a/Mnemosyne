import Foundation

/// Decides how much conversation history to send the model each turn. Tuned to
/// DeepSeek's strength — a very long (128k) and CHEAP context window — so the policy
/// is "keep the WHOLE thread verbatim until it's genuinely large, then compact only
/// the oldest turns into one summary, preserving the recent ones exactly." Pure +
/// deterministic → unit-testable; the actual summarization is injected by the caller.
enum ContextManager {
    /// Generous budget: DeepSeek handles ~128k tokens, and tokens are cheap, so we
    /// don't compact until the conversation is big. Leaves headroom for tools+answer.
    static let defaultBudgetTokens = 96_000

    /// Script-aware token estimate (~4 Latin chars/token, but ~1.5 tokens per CJK character) — a
    /// safe upper bound for budgeting that doesn't under-count Chinese/Japanese/Korean content.
    static func estimateTokens(_ text: String) -> Int { Swift.max(1, TokenEstimate.estimate(text)) }
    static func messageTokens(_ m: ChatMessage) -> Int { estimateTokens(m.content) }
    static func totalTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + messageTokens($1) }
    }

    /// Compact human label for a token count: "850", "12k", "1.2k". For indicators.
    static func humanTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return k >= 10 ? "\(Int(k.rounded()))k" : String(format: "%.1fk", k)
    }

    /// How to fit a thread into the budget: `messages[0..<compactUpTo]` get summarized,
    /// `messages[keepFrom...]` are kept verbatim. compactUpTo == 0 ⇒ keep everything
    /// (the common case — that's the long-context win).
    struct Plan: Equatable { let compactUpTo: Int; let keepFrom: Int }

    static func plan(_ messages: [ChatMessage],
                     budget: Int = defaultBudgetTokens, minRecent: Int = 6) -> Plan {
        guard totalTokens(messages) > budget, messages.count > minRecent else {
            return Plan(compactUpTo: 0, keepFrom: 0)
        }
        // Walk back from the newest, keeping a verbatim suffix up to ~70% of budget
        // (leaving room for the summary + the new answer), but always ≥ minRecent.
        let keepBudget = budget * 7 / 10
        var kept = 0
        var keepFrom = messages.count
        var i = messages.count - 1
        while i >= 0 {
            let recentCount = messages.count - i           // count if we include i
            if recentCount > minRecent, kept + messageTokens(messages[i]) > keepBudget { break }
            kept += messageTokens(messages[i]); keepFrom = i; i -= 1
        }
        return Plan(compactUpTo: keepFrom, keepFrom: keepFrom)
    }

    /// Prepend a single `.system` summary of the older turns to the kept-verbatim
    /// suffix. Empty summary ⇒ just the recent messages.
    static func assemble(recent: [ChatMessage], summary: String) -> [ChatMessage] {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return recent }
        return [ChatMessage(role: .system, content: "[Summary of earlier conversation]\n\(s)")] + recent
    }
}
