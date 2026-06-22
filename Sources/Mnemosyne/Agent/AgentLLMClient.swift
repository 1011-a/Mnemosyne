import Foundation
import Fathom

/// Bridges Mnemosyne's own `DeepSeekClient` (which owns auth, the URLSession, and
/// HTTP error handling) to the reusable `Fathom.LLMClient` protocol.
///
/// This is what lets the Ask tab's agent loop talk to the model THROUGH the SDK:
/// the wire encode/decode lives once in Fathom, while transport and
/// credentials stay with the app. Inject a different `LLMClient` (e.g. a scripted
/// mock) to drive the loop deterministically in tests.
struct AgentLLMClient: Fathom.LLMClient {
    let deepSeek: DeepSeekClient
    var temperature: Double = 0.3
    /// DeepSeek-native: when `deepseek-reasoner` is the brain, each round also returns a
    /// `reasoning_content` chain-of-thought that Fathom's `Completion` doesn't model. If set,
    /// this sink receives that reasoning per round so the tool-loop can surface a "thinking"
    /// trace. nil (default) ⇒ reasoning is ignored, exactly as before.
    var onReasoning: (@Sendable (String) -> Void)? = nil
    /// DeepSeek-native: per-round token usage, including the context-cache counters
    /// (`prompt_cache_hit_tokens`/miss) the OpenAI schema omits. If set, fires each round so the
    /// loop can surface a cache-savings note. nil (default) ⇒ usage is ignored.
    var onUsage: (@Sendable (DeepSeekUsage.Usage) -> Void)? = nil

    func complete(messages: [Fathom.ChatMessage],
                  tools: [[String: Any]]) async throws -> Fathom.Completion {
        var body: [String: Any] = [
            "model": deepSeek.config.deepSeekModel,
            "temperature": temperature,
            "messages": messages.map(Fathom.DeepSeekClient.wire),
        ]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        let data = try await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body))
        if let sink = onReasoning, let reasoning = DeepSeekReasoning.extract(from: data) {
            sink(reasoning)
        }
        if let sink = onUsage, let usage = DeepSeekUsage.parse(from: data) {
            sink(usage)
        }
        return try Fathom.DeepSeekClient.parseCompletion(data)
    }

    /// Convert the agent loop's raw `[[String: Any]]` conversation (the format DeepSeek's
    /// API expects on the wire) into the SDK's typed `ChatMessage` array. Unknown roles
    /// and malformed tool-call entries are dropped rather than crashing the turn.
    static func messages(from convo: [[String: Any]]) -> [Fathom.ChatMessage] {
        convo.compactMap { d in
            guard let roleRaw = d["role"] as? String,
                  let role = Fathom.Role(rawValue: roleRaw) else { return nil }
            let content = d["content"] as? String ?? ""
            let toolCallID = d["tool_call_id"] as? String
            var calls: [Fathom.ToolCall] = []
            if let tcs = d["tool_calls"] as? [[String: Any]] {
                calls = tcs.compactMap { tc in
                    guard let id = tc["id"] as? String,
                          let fn = tc["function"] as? [String: Any],
                          let name = fn["name"] as? String,
                          let args = fn["arguments"] as? String else { return nil }
                    return Fathom.ToolCall(id: id, name: name, arguments: args)
                }
            }
            return Fathom.ChatMessage(role: role, content: content,
                                                    toolCalls: calls, toolCallID: toolCallID)
        }
    }
}
