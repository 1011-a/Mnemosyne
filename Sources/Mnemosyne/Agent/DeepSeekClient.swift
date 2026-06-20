import Foundation

/// The Agent Brain. Talks to DeepSeek's OpenAI-compatible Chat Completions API.
/// Supports a one-shot `complete` and a token `stream` for live UI.
struct DeepSeekClient: Sendable {
    let config: Config
    private let session = URLSession(configuration: .default)

    init(config: Config) { self.config = config }

    struct WireMessage: Encodable { let role: String; let content: String }

    private func request(messages: [ChatMessage], stream: Bool, temperature: Double) throws -> URLRequest {
        var req = URLRequest(url: config.deepSeekBaseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&req)
        let body: [String: Any] = [
            "model": config.deepSeekModel,
            "stream": stream,
            "temperature": temperature,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func authorize(_ req: inout URLRequest) throws {
        let key = config.deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingDeepSeekKey }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    /// One-shot completion.
    func complete(_ messages: [ChatMessage], temperature: Double = 0.4) async throws -> String {
        let req = try request(messages: messages, stream: false, temperature: temperature)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        let parsed = try JSONDecoder().decode(CompletionResponse.self, from: data)
        return parsed.choices.first?.message.content ?? ""
    }

    /// Streaming completion — yields reasoning/answer deltas as they arrive (SSE).
    func stream(_ messages: [ChatMessage], temperature: Double = 0.4) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try request(messages: messages, stream: true, temperature: temperature)
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw ClientError.http(http.statusCode, "stream open failed")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        Self.emit(payload, to: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode one SSE payload and yield reasoning/answer deltas.
    private static func emit(_ payload: String, to continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation) {
        guard let d = payload.data(using: .utf8),
              let delta = (try? JSONDecoder().decode(StreamChunk.self, from: d))?.choices.first?.delta
        else { return }
        if let r = delta.reasoningContent, !r.isEmpty { continuation.yield(.reasoning(r)) }
        if let c = delta.content, !c.isEmpty { continuation.yield(.answer(c)) }
    }

    /// Low-level chat call accepting a pre-serialized JSON body (used by the
    /// tool-calling agent loop, which needs `tools`, `tool_calls`, and `tool`
    /// role messages the high-level `complete`/`stream` don't model).
    func rawChat(body: Data) async throws -> Data {
        var req = URLRequest(url: deepSeekBaseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&req)
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
        return data
    }

    private var deepSeekBaseURL: URL { config.deepSeekBaseURL }

    /// Stream an answer from a pre-serialized JSON body (must set "stream": true).
    /// Used by the agentic loop to stream its final answer after tool rounds.
    func rawStream(body: Data) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: deepSeekBaseURL.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    try authorize(&req)
                    req.httpBody = body
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw ClientError.http(http.statusCode, "stream open failed")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        Self.emit(payload, to: continuation)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // Wire decoding
    private struct CompletionResponse: Decodable {
        struct Choice: Decodable { let message: Msg }
        struct Msg: Decodable { let content: String }
        let choices: [Choice]
    }
    private struct StreamChunk: Decodable {
        struct Choice: Decodable { let delta: Delta }
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            enum CodingKeys: String, CodingKey { case content, reasoningContent = "reasoning_content" }
        }
        let choices: [Choice]
    }
}

/// A streamed delta — either the model's (reasoner) thinking trace or answer text.
enum StreamDelta: Sendable {
    case reasoning(String)
    case answer(String)
}

enum ClientError: Error, LocalizedError {
    case missingDeepSeekKey
    case http(Int, String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .missingDeepSeekKey: return "DeepSeek API key is missing. Add it in Settings."
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .decode(let m): return "Decode error: \(m)"
        }
    }
}
