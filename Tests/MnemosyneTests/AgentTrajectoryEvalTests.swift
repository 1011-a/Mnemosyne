import XCTest
import Fathom
@testable import Mnemosyne

/// Trace-based agent eval: drives the Ask-tab ACT loop with a scripted (no-network) SDK client and
/// asserts on the resulting TRAJECTORY (the ToolStep trace + finish reason), not just the final text.
/// Harness research: most agent failures happen mid-run, so scoring the trajectory (right tools, right
/// count, dedup, mutation, stop reason) catches what final-output scoring misses.
final class AgentTrajectoryEvalTests: XCTestCase {

    /// Scripted SDK client: returns queued completions in order; empty queue ⇒ a tool-free answer
    /// (natural finish). Sequential awaits make the plain counter safe under @unchecked Sendable.
    final class ScriptedClient: Fathom.LLMClient, @unchecked Sendable {
        private var queue: [Fathom.Completion]
        init(_ q: [Fathom.Completion]) { queue = q }
        func complete(messages: [Fathom.ChatMessage], tools: [[String: Any]]) async throws -> Fathom.Completion {
            queue.isEmpty ? .init(content: "Done.") : queue.removeFirst()
        }
    }

    private func call(_ name: String, _ args: String, id: String = "c") -> Fathom.Completion {
        .init(content: nil, toolCalls: [.init(id: id, name: name, arguments: args)])
    }

    /// Build an agent over a fresh temp store (optionally seeded with one document) driven by a script.
    private func makeAgent(_ script: [Fathom.Completion], withDoc: Bool) async throws -> ToolAgent {
        let dir = try TestSupport.tempDirectory(prefix: "Trajectory")
        let store = try KnowledgeStore(directory: dir)
        let embedder = Embedder()
        if withDoc {
            let id = "doc-tea"
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id).txt", title: "tea.txt", kind: .text,
                                    contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0,
                               text: "I drink green tea every morning.", embedding: embedder.embed("green tea"))])
        }
        let cfg = Config.load().overriding(deepSeekKey: "test-key")
        return ToolAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: cfg),
                         critic: false, llmOverride: ScriptedClient(script))
    }

    // Scenario A — correct single-tool research, then answer: trajectory = one fresh search that cites.
    func testTrajectorySingleToolResearch() async throws {
        let agent = try await makeAgent([call("search_knowledge", #"{"query":"tea"}"#)], withDoc: true)
        let phase = try await agent.runToolRounds(query: "Look up what I drink", history: [], onStatus: { _ in })
        XCTAssertEqual(phase.finish, .natural)
        XCTAssertEqual(phase.trace.map(\.tool), ["search_knowledge"])
        let step = try XCTUnwrap(phase.trace.first)
        XCTAssertFalse(step.repeated); XCTAssertFalse(step.mutated)
        XCTAssertGreaterThan(step.newCitations, 0, "the search produced cited evidence")
    }

    // Scenario B — de-dup: the same call twice is recognized as a repeat (not re-executed).
    func testTrajectoryDeDupesRepeatCall() async throws {
        let agent = try await makeAgent([
            call("search_knowledge", #"{"query":"tea"}"#, id: "1"),
            call("search_knowledge", #"{"query":"tea"}"#, id: "2"),   // identical → repeat
        ], withDoc: true)
        let phase = try await agent.runToolRounds(query: "Look up what I drink", history: [], onStatus: { _ in })
        XCTAssertEqual(phase.finish, .natural)
        XCTAssertEqual(phase.trace.count, 2)
        XCTAssertFalse(phase.trace[0].repeated)
        XCTAssertTrue(phase.trace[1].repeated, "second identical call flagged as a repeat")
    }

    // Scenario C — no-progress stop: repeated all-repeat rounds end the loop with .noProgress.
    func testTrajectoryStallStopsWithNoProgress() async throws {
        let agent = try await makeAgent([
            call("list_tags", "{}", id: "1"),
            call("list_tags", "{}", id: "2"),   // repeat → stall 1
            call("list_tags", "{}", id: "3"),   // repeat → stall 2 → stop
        ], withDoc: false)
        let phase = try await agent.runToolRounds(query: "Tidy up my labels", history: [], onStatus: { _ in })
        XCTAssertEqual(phase.finish, .noProgress)
        XCTAssertEqual(phase.trace.first?.tool, "list_tags")
        XCTAssertTrue(phase.trace.dropFirst().allSatisfy(\.repeated), "later rounds were all repeats")
    }

    // Scenario D — mutation is tracked: pin_fact (a knowledge-base mutation) marks the step mutated.
    func testTrajectoryRecordsMutation() async throws {
        let agent = try await makeAgent([call("pin_fact", #"{"fact":"I drink green tea"}"#)], withDoc: false)
        let phase = try await agent.runToolRounds(query: "Remember that I drink green tea", history: [], onStatus: { _ in })
        XCTAssertEqual(phase.finish, .natural)
        let step = try XCTUnwrap(phase.trace.first { $0.tool == "pin_fact" })
        XCTAssertTrue(step.mutated, "pin_fact recorded as a mutation")
    }
}
