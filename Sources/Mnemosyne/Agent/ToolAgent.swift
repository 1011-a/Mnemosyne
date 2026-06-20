import Foundation

/// Agentic brain: instead of one-shot RAG, DeepSeek drives a tool-calling loop.
/// It can call `search_knowledge` as many times as it needs (multi-hop) to
/// gather evidence before answering — better for comparative / multi-part
/// questions. Every retrieved source becomes a numbered citation.
struct ToolAgent: Sendable {
    let store: KnowledgeStore
    let embedder: Embedder
    let deepSeek: DeepSeekClient
    var topK: Int = 6
    var temperature: Double = 0.3
    var keywordWeight: Float = 0.3
    var maxRounds: Int = 4

    struct Answer: Sendable {
        let text: String
        let citations: [Citation]
        let searches: Int
    }

    static let systemPrompt = """
    You are Mnemosyne, a personal-knowledge agent answering strictly from the user's own indexed \
    files on this Mac. You have a tool, search_knowledge, that does semantic search over those files. \
    Strategy:
    • ALWAYS search before answering. For multi-part or comparative questions, issue several \
      searches with different phrasings.
    • Use ONLY the returned sources. Cite every claim inline with bracketed numbers like [1], [2] \
      that match the source numbers from the tool results.
    • If nothing relevant is found, say so and suggest what to ingest. Match the user's language.
    • FORMAT: open with ONE summary sentence, then 2–5 short "- " bullet points when there are \
      multiple findings. No preamble, no headings.
    """

    // Built fresh each call — a static `[String: Any]` isn't Sendable in Swift 6.
    private static func searchTool() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "search_knowledge",
                "description": "Semantic search over the user's personal knowledge base. Returns numbered source snippets.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "A focused natural-language search query."]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    /// Result of the tool-calling phase: the full conversation (system + history
    /// + tool results), accumulated citations, and how many searches ran.
    private struct ToolPhase { var convo: [[String: Any]]; var citations: [Citation]; var searches: Int }

    /// Run search rounds until the model stops requesting tools (or rounds run
    /// out). Stops BEFORE the model writes its prose answer, so the caller can
    /// generate that final answer streamed or non-streamed as it likes.
    private func runToolRounds(query: String, history: [ChatMessage],
                               onStatus: @Sendable @escaping (String) -> Void) async throws -> ToolPhase {
        var convo: [[String: Any]] = [["role": "system", "content": Self.systemPrompt]]
        for m in history where m.role == .user || m.role == .assistant {
            let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { convo.append(["role": m.role.rawValue, "content": t]) }
        }
        convo.append(["role": "user", "content": query])

        var citations: [Citation] = []
        var searches = 0

        // Guarantee the user's OWN query is searched up-front. The model sometimes
        // rephrases (especially across languages) into queries that miss an exact
        // name like a person's, then concludes "not found" — seeding the original
        // query's results means directly-relevant docs are never missed.
        let seedHits = (try? await store.search(vector: embedder.embed(query), queryText: query,
                                                k: topK, keywordWeight: keywordWeight)) ?? []
        if !seedHits.isEmpty {
            onStatus("Searching: \(query)")
            searches += 1
            let (seedText, seedCites) = render(seedHits, startingAt: citations.count)
            citations.append(contentsOf: seedCites)
            let seedArgs = (try? JSONSerialization.data(withJSONObject: ["query": query]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            convo.append([
                "role": "assistant", "content": "",
                "tool_calls": [["id": "seed-0", "type": "function",
                                "function": ["name": "search_knowledge", "arguments": seedArgs]]]
            ])
            convo.append(["role": "tool", "tool_call_id": "seed-0", "content": seedText])
        }

        for _ in 0..<maxRounds {
            let body: [String: Any] = [
                "model": deepSeek.config.deepSeekModel,
                "messages": convo,
                "temperature": temperature,
                "tools": [Self.searchTool()],
                "tool_choice": "auto"
            ]
            let data = try await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body))
            let resp = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let msg = resp.choices.first?.message,
                  let calls = msg.toolCalls, !calls.isEmpty else {
                break   // model is ready to answer — stop here, discard any draft content
            }
            convo.append([
                "role": "assistant", "content": msg.content ?? "",
                "tool_calls": calls.map { [
                    "id": $0.id, "type": "function",
                    "function": ["name": $0.function.name, "arguments": $0.function.arguments]
                ] }
            ])
            for call in calls {
                let q = Self.queryArgument(call.function.arguments) ?? query
                searches += 1
                onStatus("Searching: \(q)")
                let hits = (try? await store.search(vector: embedder.embed(q), queryText: q,
                                                    k: topK, keywordWeight: keywordWeight)) ?? []
                let (resultText, newCites) = render(hits, startingAt: citations.count)
                citations.append(contentsOf: newCites)
                convo.append(["role": "tool", "tool_call_id": call.id, "content": resultText])
            }
        }
        onStatus("")
        return ToolPhase(convo: convo, citations: citations, searches: searches)
    }

    private func finalBody(_ convo: [[String: Any]], stream: Bool) -> [String: Any] {
        ["model": deepSeek.config.deepSeekModel, "messages": convo,
         "temperature": temperature, "tool_choice": "none", "stream": stream]
    }

    /// Non-streaming: run tool rounds, then generate the grounded answer.
    func answer(query: String,
                history: [ChatMessage],
                onStatus: @Sendable @escaping (String) -> Void = { _ in }) async throws -> Answer {
        let phase = try await runToolRounds(query: query, history: history, onStatus: onStatus)
        let data = try await deepSeek.rawChat(
            body: JSONSerialization.data(withJSONObject: finalBody(phase.convo, stream: false)))
        let resp = try JSONDecoder().decode(ChatResponse.self, from: data)
        return Answer(text: resp.choices.first?.message.content ?? "",
                      citations: phase.citations, searches: phase.searches)
    }

    /// Streaming: run tool rounds, surface citations, then stream the final answer
    /// token-by-token (`onCitations` fires once searching is done).
    func answerStream(query: String,
                      history: [ChatMessage],
                      onStatus: @Sendable @escaping (String) -> Void = { _ in },
                      onCitations: @Sendable @escaping ([Citation]) -> Void = { _ in })
        -> AsyncThrowingStream<StreamDelta, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let phase = try await runToolRounds(query: query, history: history, onStatus: onStatus)
                    onCitations(phase.citations)
                    let body = try JSONSerialization.data(withJSONObject: finalBody(phase.convo, stream: true))
                    for try await token in deepSeek.rawStream(body: body) {
                        if Task.isCancelled { break }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turn hits into a numbered tool-result string and matching citations.
    private func render(_ hits: [RetrievedChunk], startingAt offset: Int) -> (String, [Citation]) {
        guard !hits.isEmpty else { return ("No matching sources found.", []) }
        var text = ""
        var cites: [Citation] = []
        for (i, hit) in hits.enumerated() {
            let n = offset + i + 1
            let snippet = String(hit.chunk.text.prefix(600)).replacingOccurrences(of: "\n", with: " ")
            text += "[\(n)] (\(hit.item.title)) \(snippet)\n"
            cites.append(Citation(index: n, title: hit.item.title, path: hit.item.path,
                                  snippet: snippet, itemID: hit.item.id))
        }
        return (text, cites)
    }

    static func queryArgument(_ argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = obj["query"] as? String,
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return q
    }

    // MARK: Wire decoding
    struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCall]?
            enum CodingKeys: String, CodingKey { case content, toolCalls = "tool_calls" }
        }
        let choices: [Choice]
    }
    struct ToolCall: Decodable {
        let id: String
        let function: Function
        struct Function: Decodable { let name: String; let arguments: String }
    }
}
