import XCTest
@testable import Mnemosyne

final class AgentTests: XCTestCase {

    private func chunk(_ n: Int, title: String, text: String) -> RetrievedChunk {
        let item = KnowledgeItem(id: "i\(n)", path: "/tmp/\(title)", title: title, kind: .text,
                                 contentHash: "h\(n)", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        let c = Chunk(id: "i\(n)#0", itemID: "i\(n)", ordinal: 0, text: text, embedding: [])
        return RetrievedChunk(chunk: c, item: item, score: Float(1) / Float(n))
    }

    func testBuildMessagesGroundsWithNumberedSources() {
        let retrieved = [
            chunk(1, title: "notes.md", text: "FAISS indexes embeddings for nearest-neighbor search."),
            chunk(2, title: "cooking.txt", text: "Risotto needs warm stock.")
        ]
        let (messages, citations) = RAGAgent.buildMessages(
            query: "How do I search embeddings?", history: [], retrieved: retrieved)

        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages.contains { $0.content.contains("SOURCES:") && $0.content.contains("[1] (notes.md)") })
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.content, "How do I search embeddings?")
        XCTAssertEqual(citations.map(\.index), [1, 2])
        XCTAssertEqual(citations.first?.title, "notes.md")
    }

    func testBuildMessagesWithoutSourcesIsHonest() {
        let (messages, citations) = RAGAgent.buildMessages(query: "anything", history: [], retrieved: [])
        XCTAssertTrue(messages.contains { $0.content.contains("none found") })
        XCTAssertTrue(citations.isEmpty)
    }

    func testHistoryIsCarriedButSystemRolesDropped() {
        let history = [
            ChatMessage(role: .user, content: "earlier question"),
            ChatMessage(role: .assistant, content: "earlier answer"),
            ChatMessage(role: .system, content: "should be ignored")
        ]
        let (messages, _) = RAGAgent.buildMessages(query: "new q", history: history, retrieved: [])
        let userAssistant = messages.filter { $0.role == .user || $0.role == .assistant }
        XCTAssertEqual(userAssistant.map(\.content), ["earlier question", "earlier answer", "new q"])
        XCTAssertFalse(messages.contains { $0.content == "should be ignored" })
    }

    func testReferencedIndicesParsing() {
        XCTAssertEqual(RAGAgent.referencedIndices(in: "Per [1] and [3], also [12]."), [1, 3, 12])
        XCTAssertEqual(RAGAgent.referencedIndices(in: "grouped [2][4]"), [2, 4])
        XCTAssertEqual(RAGAgent.referencedIndices(in: "no refs here"), [])
        XCTAssertEqual(RAGAgent.referencedIndices(in: "ignore [abc] markdown [link](x)"), [])
    }

    /// Live end-to-end: ingest a tiny corpus, ask a question, stream a grounded
    /// answer from DeepSeek. Skips cleanly if offline or no key.
    func testLiveGroundedAnswer() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled,
                          "set MNEMO_LIVE_DEEPSEEK=1 to run this quota-spending live test")
        let config = Config.load()
        try XCTSkipIf(config.deepSeekKey.isEmpty, "no DeepSeek key configured")
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoRAG-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        let text = "Project Mnemosyne stores embeddings in SQLite and uses FAISS-style cosine search to retrieve a user's notes."
        let item = KnowledgeItem(id: "doc1", path: "/tmp/arch.md", title: "arch.md", kind: .markdown,
                                 contentHash: "x", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        let c = Chunk(id: "doc1#0", itemID: "doc1", ordinal: 0, text: text, embedding: embedder.embed(text))
        try await store.upsert(item: item, chunks: [c])

        let agent = RAGAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: config))
        let prepared = try await agent.prepare(query: "How does Mnemosyne retrieve notes?", history: [])
        XCTAssertEqual(prepared.retrievedCount, 1)

        var answer = ""
        do {
            for try await delta in agent.stream(prepared.messages) {
                if case .answer(let a) = delta { answer += a }
            }
        } catch {
            throw XCTSkip("network/API unavailable: \(error.localizedDescription)")
        }
        XCTAssertFalse(answer.isEmpty, "DeepSeek should return a grounded answer")
        let mentionsSource = answer.contains("[1]") || answer.lowercased().contains("sqlite")
            || answer.lowercased().contains("cosine") || answer.lowercased().contains("faiss")
        XCTAssertTrue(mentionsSource, "answer should be grounded in the source; got: \(answer.prefix(200))")
    }
}
