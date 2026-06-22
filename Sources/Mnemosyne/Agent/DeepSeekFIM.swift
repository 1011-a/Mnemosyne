import Foundation

/// Builds requests for DeepSeek's **beta FIM (fill-in-the-middle) completion** — a native feature
/// (no OpenAI chat equivalent) on the `/beta/completions` endpoint: give a `prompt` (the code/text
/// BEFORE the gap) and a `suffix` (what comes AFTER), and the model generates the middle. Ideal
/// for inserting a function body, a missing block, or a between-the-lines edit. Pure
/// request-builder (no I/O) → unit-testable. Companion to [[DeepSeekPrefix]].
enum DeepSeekFIM {
    /// FIM request body for `POST {base}/beta/completions`. `suffix` empty ⇒ a plain (prefix-only)
    /// completion. `maxTokens` <= 0 ⇒ omitted (let the server default).
    static func body(prompt: String, suffix: String, model: String,
                     maxTokens: Int = 0, temperature: Double = 0.2) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "temperature": temperature,
        ]
        if !suffix.isEmpty { body["suffix"] = suffix }
        if maxTokens > 0 { body["max_tokens"] = maxTokens }
        return body
    }

    /// Extract the generated middle from a `/completions` (text-completion) response body — the
    /// first choice's `text`. nil when absent or undecodable.
    static func extractText(from data: Data) -> String? {
        struct Wire: Decodable {
            struct Choice: Decodable { let text: String? }
            let choices: [Choice]?
        }
        return (try? JSONDecoder().decode(Wire.self, from: data))?.choices?.first?.text
    }
}
