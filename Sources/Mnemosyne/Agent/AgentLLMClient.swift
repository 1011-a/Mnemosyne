import Foundation
import DeepSeekOrchestrator

/// Bridges Mnemosyne's own `DeepSeekClient` (which owns auth, the URLSession, and
/// HTTP error handling) to the reusable `DeepSeekOrchestrator.LLMClient` protocol.
///
/// This is what lets the Ask tab's agent loop talk to the model THROUGH the SDK:
/// the wire encode/decode lives once in `DeepSeekOrchestrator`, while transport and
/// credentials stay with the app. Inject a different `LLMClient` (e.g. a scripted
/// mock) to drive the loop deterministically in tests.
struct AgentLLMClient: DeepSeekOrchestrator.LLMClient {
    let deepSeek: DeepSeekClient
    var temperature: Double = 0.3

    func complete(messages: [DeepSeekOrchestrator.ChatMessage],
                  tools: [[String: Any]]) async throws -> DeepSeekOrchestrator.Completion {
        var body: [String: Any] = [
            "model": deepSeek.config.deepSeekModel,
            "temperature": temperature,
            "messages": messages.map(DeepSeekOrchestrator.DeepSeekClient.wire),
        ]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        let data = try await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body))
        return try DeepSeekOrchestrator.DeepSeekClient.parseCompletion(data)
    }

    /// Convert the agent loop's raw `[[String: Any]]` conversation (the format DeepSeek's
    /// API expects on the wire) into the SDK's typed `ChatMessage` array. Unknown roles
    /// and malformed tool-call entries are dropped rather than crashing the turn.
    static func messages(from convo: [[String: Any]]) -> [DeepSeekOrchestrator.ChatMessage] {
        convo.compactMap { d in
            guard let roleRaw = d["role"] as? String,
                  let role = DeepSeekOrchestrator.Role(rawValue: roleRaw) else { return nil }
            let content = d["content"] as? String ?? ""
            let toolCallID = d["tool_call_id"] as? String
            var calls: [DeepSeekOrchestrator.ToolCall] = []
            if let tcs = d["tool_calls"] as? [[String: Any]] {
                calls = tcs.compactMap { tc in
                    guard let id = tc["id"] as? String,
                          let fn = tc["function"] as? [String: Any],
                          let name = fn["name"] as? String,
                          let args = fn["arguments"] as? String else { return nil }
                    return DeepSeekOrchestrator.ToolCall(id: id, name: name, arguments: args)
                }
            }
            return DeepSeekOrchestrator.ChatMessage(role: role, content: content,
                                                    toolCalls: calls, toolCallID: toolCallID)
        }
    }
}
