import XCTest
@testable import Mnemosyne

final class ToolAgentTests: XCTestCase {

    func testQueryArgumentParsing() {
        XCTAssertEqual(ToolAgent.queryArgument(#"{"query":"vector search"}"#), "vector search")
        XCTAssertEqual(ToolAgent.queryArgument(#"{"query":"FAISS","k":5}"#), "FAISS")
        XCTAssertNil(ToolAgent.queryArgument(#"{"query":"   "}"#))
        XCTAssertNil(ToolAgent.queryArgument("not json"))
        XCTAssertNil(ToolAgent.queryArgument(#"{"other":"x"}"#))
    }

    func testChatResponseDecodingWithToolCalls() throws {
        let json = """
        {"choices":[{"message":{"content":null,"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"search_knowledge","arguments":"{\\"query\\":\\"faiss\\"}"}}
        ]}}]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ToolAgent.ChatResponse.self, from: json)
        let msg = try XCTUnwrap(resp.choices.first?.message)
        XCTAssertNil(msg.content)
        XCTAssertEqual(msg.toolCalls?.count, 1)
        XCTAssertEqual(msg.toolCalls?.first?.function.name, "search_knowledge")
        XCTAssertEqual(ToolAgent.queryArgument(msg.toolCalls!.first!.function.arguments), "faiss")
    }

    func testChatResponseDecodingPlainAnswer() throws {
        let json = #"{"choices":[{"message":{"content":"Here is the answer [1]."}}]}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ToolAgent.ChatResponse.self, from: json)
        XCTAssertEqual(resp.choices.first?.message.content, "Here is the answer [1].")
        XCTAssertNil(resp.choices.first?.message.toolCalls)
    }

    /// Live: the agent should call search_knowledge, find the ingested doc, and
    /// answer with a citation — proving the full multi-hop tool loop end-to-end.
    func testLiveAgenticLoopSearchesAndCites() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled,
                          "set MNEMO_LIVE_DEEPSEEK=1 to run this quota-spending live test")
        let config = Config.load()
        try XCTSkipIf(config.deepSeekKey.isEmpty, "no DeepSeek key")
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MnemoTool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        let text = "The Mnemosyne project indexes files locally and answers questions using DeepSeek as its agent brain with a SQLite-backed cosine vector store."
        let item = KnowledgeItem(id: "d1", path: "/tmp/about.md", title: "about.md", kind: .markdown,
                                 contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        try await store.upsert(item: item, chunks: [
            Chunk(id: "d1#0", itemID: "d1", ordinal: 0, text: text, embedding: embedder.embed(text))
        ])

        let agent = ToolAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: config))
        let answer: ToolAgent.Answer
        do {
            answer = try await agent.answer(query: "What does Mnemosyne use as its agent brain?", history: [])
        } catch {
            throw XCTSkip("network/API unavailable: \(error.localizedDescription)")
        }
        XCTAssertGreaterThanOrEqual(answer.searches, 1, "agent should have called the search tool")
        XCTAssertFalse(answer.citations.isEmpty, "answer should accumulate citations from searches")
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertTrue(answer.text.lowercased().contains("deepseek"),
                      "answer should be grounded in the source; got: \(answer.text.prefix(200))")
    }

    /// Live: the streaming agentic path should search, surface citations, then
    /// stream the final answer in multiple token chunks.
    func testLiveAgenticStreamingYieldsTokensAndCitations() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled,
                          "set MNEMO_LIVE_DEEPSEEK=1 to run this quota-spending live test")
        let config = Config.load()
        try XCTSkipIf(config.deepSeekKey.isEmpty, "no DeepSeek key")
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MnemoStream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let text = "Mnemosyne runs entirely on your Mac and uses Gemma 3 12B locally to understand images and PDFs."
        try await store.upsert(
            item: KnowledgeItem(id: "g", path: "/tmp/g.md", title: "g.md", kind: .markdown,
                                contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
            chunks: [Chunk(id: "g#0", itemID: "g", ordinal: 0, text: text, embedding: embedder.embed(text))])

        let agent = ToolAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: config))
        let citeBox = CiteBox()
        var chunks = 0
        var full = ""
        do {
            let stream = agent.answerStream(query: "What model does Mnemosyne use for images?",
                                            history: [],
                                            onCitations: { citeBox.set($0) })
            for try await delta in stream {
                if case .answer(let a) = delta { chunks += 1; full += a }
            }
        } catch {
            throw XCTSkip("network/API unavailable: \(error.localizedDescription)")
        }
        XCTAssertGreaterThan(chunks, 1, "answer should arrive in multiple streamed chunks")
        XCTAssertFalse(citeBox.get().isEmpty, "citations should be surfaced before streaming")
        XCTAssertTrue(full.lowercased().contains("gemma"), "answer should be grounded; got: \(full.prefix(160))")
    }
}

/// Thread-safe holder for citations captured from the @Sendable callback.
final class CiteBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: [Citation] = []
    func set(_ v: [Citation]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [Citation] { lock.lock(); defer { lock.unlock() }; return value }
}
