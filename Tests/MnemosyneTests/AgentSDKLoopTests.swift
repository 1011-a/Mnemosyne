import XCTest
import DeepSeekOrchestrator
@testable import Mnemosyne

/// Proves the Ask tab's agent ACT loop drives its model calls through the
/// `DeepSeekOrchestrator` SDK — by injecting a scripted SDK `LLMClient` (no network)
/// and confirming the loop multi-rounds, threads the tool call back, and finishes.
final class AgentSDKLoopTests: XCTestCase {

    /// A scripted SDK client: returns queued completions in order, counting calls.
    /// The agent loop calls `complete` strictly sequentially (await per round), so a
    /// plain counter is safe under `@unchecked Sendable` — no lock needed.
    final class MockSDKClient: DeepSeekOrchestrator.LLMClient, @unchecked Sendable {
        private var queue: [DeepSeekOrchestrator.Completion]
        private(set) var invocations = 0
        init(_ q: [DeepSeekOrchestrator.Completion]) { queue = q }
        func complete(messages: [DeepSeekOrchestrator.ChatMessage],
                      tools: [[String: Any]]) async throws -> DeepSeekOrchestrator.Completion {
            invocations += 1
            return queue.isEmpty ? .init(content: "done") : queue.removeFirst()
        }
    }

    func testActLoopRunsThroughSDK() async throws {
        let dir = try TestSupport.tempDirectory(prefix: "SDKLoop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let embedder = Embedder()
        // One document so search_knowledge has something real to return.
        let id = "doc-tea"
        try await store.upsert(
            item: KnowledgeItem(id: id, path: "/tmp/\(id).txt", title: "tea.txt", kind: .text,
                                contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
            chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0,
                           text: "I like green tea in the morning.", embedding: embedder.embed("green tea"))])

        // Round 1: the model asks for a tool. Round 2: it answers (no tools) → natural finish.
        let mock = MockSDKClient([
            .init(content: nil, toolCalls: [.init(id: "c1", name: "search_knowledge",
                                                  arguments: #"{"query":"tea"}"#)]),
            .init(content: "You like green tea."),
        ])

        // Key never used: the injected mock replaces the network entirely.
        let cfg = Config.load().overriding(deepSeekKey: "test-key")
        let agent = ToolAgent(store: store, embedder: embedder,
                              deepSeek: DeepSeekClient(config: cfg),
                              critic: false, llmOverride: mock)

        // An action-style query so the loop (not the up-front seed search) drives the tool.
        let phase = try await agent.runToolRounds(
            query: "Look up what I drink", history: [], onStatus: { _ in })

        XCTAssertGreaterThanOrEqual(mock.invocations, 2, "the loop multi-rounded through the SDK client")
        XCTAssertEqual(phase.finish, .natural, "the model stopped requesting tools")
        // The SDK Completion's tool call was threaded back into the conversation…
        let assistantCalls = phase.convo.contains { m in
            (m["role"] as? String) == "assistant" &&
            ((m["tool_calls"] as? [[String: Any]])?.contains {
                (($0["function"] as? [String: Any])?["name"] as? String) == "search_knowledge"
            } ?? false)
        }
        XCTAssertTrue(assistantCalls, "the search_knowledge call was recorded in the transcript")
        // …and the tool actually ran, producing a citation from the stored document.
        XCTAssertTrue(phase.citations.contains { $0.title == "tea.txt" },
                      "search_knowledge executed and cited the real document")
    }
}
