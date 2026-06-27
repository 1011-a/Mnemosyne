import Foundation

/// Pulls DeepSeek's native `reasoning_content` out of a chat-completions response body — the
/// chain-of-thought that `deepseek-v4-pro` (R1) emits alongside its answer/tool calls. Fathom's
/// `Completion` only models `content` + `tool_calls`, so this app-side helper recovers the
/// reasoning that the SDK's `parseCompletion` drops, letting the agent tool-loop surface a live
/// "thinking" trace. Pure + deterministic → unit-testable.
enum DeepSeekReasoning {
    private struct Wire: Decodable {
        struct Choice: Decodable { let message: Msg? }
        struct Msg: Decodable {
            let reasoningContent: String?
            enum CodingKeys: String, CodingKey { case reasoningContent = "reasoning_content" }
        }
        let choices: [Choice]?
    }

    /// The first choice's `reasoning_content`, trimmed. nil when absent, empty, or the body
    /// isn't decodable (e.g. deepseek-v4-flash, which has no reasoning field).
    static func extract(from data: Data) -> String? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let raw = wire.choices?.first?.message?.reasoningContent else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A one-line trace snippet for the activity log: the first non-empty line, collapsed of
    /// inner whitespace and truncated to `max` characters with an ellipsis. nil if empty.
    static func snippet(_ reasoning: String, max: Int = 140) -> String? {
        let firstLine = reasoning
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = firstLine else { return nil }
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= max { return collapsed }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: max)
        return String(collapsed[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
