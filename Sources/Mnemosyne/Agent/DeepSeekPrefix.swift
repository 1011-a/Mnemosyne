import Foundation

/// Builds requests for DeepSeek's **beta chat-prefix completion** — a native feature (no OpenAI
/// equivalent) where the final message is an assistant turn flagged `prefix: true`, and the model
/// *continues from that text* instead of starting fresh. Perfect for constrained outputs: force a
/// reply to begin with ```json, a required heading, or a partial sentence, optionally stopping at
/// a delimiter. Pure request-builder (no I/O) → unit-testable. Companion to [[DeepSeekUsage]] /
/// [[DeepSeekReasoning]].
///
/// Beta features require the `/beta` base path; `betaBaseURL` derives it from the configured host.
enum DeepSeekPrefix {
    /// Map any DeepSeek base URL to the `/beta` endpoint root (where prefix/FIM live):
    /// `https://api.deepseek.com` or `.../v1` → `https://api.deepseek.com/beta`.
    static func betaBaseURL(_ base: URL) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = "/beta"
        comps?.query = nil
        return comps?.url ?? base
    }

    /// Append the assistant prefix turn (`prefix: true`) as the LAST message, so the model
    /// continues it. Returns the full wire `messages` array.
    static func messages(_ prior: [[String: Any]], prefix: String) -> [[String: Any]] {
        prior + [["role": "assistant", "content": prefix, "prefix": true]]
    }

    /// Full request body for a beta chat-prefix completion. `stop` (when non-empty) tells the
    /// model where to halt — e.g. ["```"] to capture exactly one fenced block.
    static func body(prior: [[String: Any]], prefix: String, model: String,
                     temperature: Double = 0.3, stop: [String] = []) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": messages(prior, prefix: prefix),
        ]
        if !stop.isEmpty { body["stop"] = stop }
        return body
    }
}
