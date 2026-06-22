import Foundation

/// Builds requests for DeepSeek's native **JSON Output mode** (`response_format: {type:
/// json_object}`) — the official way to force valid JSON on the standard chat endpoint, more
/// robust than seeding a ```json prefix. DeepSeek requires the word "json" to appear somewhere in
/// the messages, or the request errors; this helper guarantees that. Pure request-builder (no I/O)
/// → unit-testable. Companion to [[JSONExtract]] / [[DeepSeekPrefix]].
enum JSONMode {
    /// Full request body with `response_format` set and the JSON hint ensured.
    static func body(prior: [[String: Any]], model: String, temperature: Double = 0.2) -> [String: Any] {
        [
            "model": model,
            "temperature": temperature,
            "messages": ensureJSONHint(prior),
            "response_format": ["type": "json_object"],
        ]
    }

    /// DeepSeek rejects JSON mode unless some message mentions "json". If none does, prepend a
    /// short system instruction so the request is always valid; otherwise return `prior` unchanged.
    static func ensureJSONHint(_ prior: [[String: Any]]) -> [[String: Any]] {
        let mentionsJSON = prior.contains { msg in
            (msg["content"] as? String)?.lowercased().contains("json") ?? false
        }
        guard !mentionsJSON else { return prior }
        let hint: [String: Any] = ["role": "system", "content": "Respond with a single valid JSON object."]
        return [hint] + prior
    }
}
