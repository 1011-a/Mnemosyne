import Foundation

/// Retrieval-augmented agent. Embeds the query, pulls the most relevant chunks
/// from the knowledge base, grounds DeepSeek with numbered sources, and streams
/// an answer that cites them. Prompt assembly is pure & network-free for testing.
struct RAGAgent: Sendable {
    let store: KnowledgeStore
    let embedder: Embedder
    let deepSeek: DeepSeekClient
    var topK: Int = 8
    var temperature: Double = 0.3
    var keywordWeight: Float = 0.3
    var maxCharsPerSource: Int = 700
    /// When true, DeepSeek expands/clarifies the query (resolving pronouns from
    /// history) before embedding — improves recall on terse follow-ups.
    var queryRewrite: Bool = false

    /// Everything needed to stream an answer for one user turn.
    struct Prepared: Sendable {
        let messages: [ChatMessage]
        let citations: [Citation]
        let retrievedCount: Int
    }

    /// Retrieve + assemble the grounded prompt for `query`.
    func prepare(query: String, history: [ChatMessage]) async throws -> Prepared {
        let searchQuery = queryRewrite ? await rewrite(query, history: history) : query
        let vector = embedder.embed(searchQuery)
        // Always search: even when the embedder can't vectorise the query (e.g. a
        // Chinese question), the keyword signal can still retrieve by exact term.
        let hits = try await store.search(
            vector: vector, queryText: searchQuery, k: topK, keywordWeight: keywordWeight)
        // The answer is always grounded against the user's ORIGINAL question.
        let (messages, citations) = Self.buildMessages(
            query: query, history: history, retrieved: hits, maxCharsPerSource: maxCharsPerSource)
        return Prepared(messages: messages, citations: citations, retrievedCount: hits.count)
    }

    /// Stream the assistant's deltas (reasoning + answer) for a prepared prompt.
    func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        deepSeek.stream(messages, temperature: temperature)
    }

    /// Best-effort search-query expansion. Falls back to the original on failure.
    private func rewrite(_ query: String, history: [ChatMessage]) async -> String {
        let recent = history.suffix(4)
            .map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        let prompt = """
        Rewrite the user's question into a single, self-contained search query for a vector \
        database of their personal files. Resolve pronouns using the conversation. Output ONLY the \
        rewritten query, no preamble.

        Conversation:
        \(recent)

        Question: \(query)
        """
        let result = try? await deepSeek.complete(
            [ChatMessage(role: .user, content: prompt)], temperature: 0.0)
        let cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? query : cleaned
    }

    /// A short title for a thread based on its opening message (best-effort).
    func suggestTitle(from text: String) async -> String? {
        let prompt = "Give a concise 3–6 word title (no quotes, no trailing punctuation) for a conversation that begins with:\n\(text)"
        guard let r = try? await deepSeek.complete([ChatMessage(role: .user, content: prompt)], temperature: 0.2) else { return nil }
        let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.。"))
        return t.isEmpty ? nil : String(t.prefix(48))
    }

    // MARK: - Pure prompt assembly

    static let systemPrompt = """
    You are Mnemosyne, a personal-knowledge assistant that answers strictly from the user's own \
    indexed data on this Mac. Follow these rules:
    • Answer ONLY using the numbered SOURCES provided. Do not use outside knowledge or invent facts.
    • Cite every claim inline with bracketed source numbers like [1] or [2][3].
    • If the sources do not contain the answer, say so plainly and suggest what to ingest or ask next.
    • Match the user's language (English or 中文).
    FORMAT: Begin with ONE concise summary sentence. Then, when there are multiple findings, give \
    2–5 short bullet points (each starting with "- "). Keep it tight — no preamble, no headings.
    """

    static func buildMessages(query: String,
                              history: [ChatMessage],
                              retrieved: [RetrievedChunk],
                              maxCharsPerSource: Int = 700) -> ([ChatMessage], [Citation]) {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: systemPrompt)]
        var citations: [Citation] = []

        if retrieved.isEmpty {
            messages.append(ChatMessage(role: .system,
                content: "SOURCES: (none found in the knowledge base for this query.)"))
        } else {
            var block = "SOURCES:\n"
            for (i, hit) in retrieved.enumerated() {
                let n = i + 1
                let snippet = String(hit.chunk.text.prefix(maxCharsPerSource))
                    .replacingOccurrences(of: "\n", with: " ")
                block += "[\(n)] (\(hit.item.title)) \(snippet)\n"
                citations.append(Citation(index: n, title: hit.item.title,
                                          path: hit.item.path, snippet: snippet, itemID: hit.item.id))
            }
            messages.append(ChatMessage(role: .system, content: block))
        }

        // Prior conversation (user/assistant only), then the new question.
        for m in history where m.role == .user || m.role == .assistant {
            let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { messages.append(ChatMessage(role: m.role, content: text)) }
        }
        messages.append(ChatMessage(role: .user, content: query))
        return (messages, citations)
    }

    /// Which citation numbers the answer text actually referenced (for UI pruning).
    static func referencedIndices(in answer: String) -> Set<Int> {
        var found = Set<Int>()
        var num = ""
        var inside = false
        for ch in answer {
            if ch == "[" { inside = true; num = "" }
            else if ch == "]" { if let n = Int(num) { found.insert(n) }; inside = false; num = "" }
            else if inside, ch.isNumber { num.append(ch) }
            else if inside, ch != " " && ch != "," { inside = false }
        }
        return found
    }
}
