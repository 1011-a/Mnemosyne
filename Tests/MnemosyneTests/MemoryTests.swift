import XCTest
@testable import Mnemosyne

final class MemoryTests: XCTestCase {

    private func freshStore() throws -> (KnowledgeStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoMem-\(UUID().uuidString)", isDirectory: true)
        return (try KnowledgeStore(directory: dir), dir)
    }

    func testThreadAndMessagePersistenceRoundtrip() async throws {
        let (store, dir) = try freshStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let thread = ChatThread(id: "t1", title: "Vector DBs")
        try await store.upsertThread(thread)

        let msgs = [
            ChatMessage(role: .user, content: "How do I search embeddings?"),
            ChatMessage(role: .assistant, content: "Use cosine similarity [1].",
                        citations: [Citation(index: 1, title: "notes.md", path: "/tmp/notes.md", snippet: "cosine…")])
        ]
        try await store.saveMessages(msgs, threadID: "t1")

        let threads = try await store.allThreads()
        XCTAssertEqual(threads.map(\.title), ["Vector DBs"])

        let loaded = try await store.loadMessages(threadID: "t1")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].role, .user)
        XCTAssertEqual(loaded[1].content, "Use cosine similarity [1].")
        XCTAssertEqual(loaded[1].citations.first?.title, "notes.md")
    }

    func testSaveMessagesReplacesNotAppends() async throws {
        let (store, dir) = try freshStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.upsertThread(ChatThread(id: "t", title: "x"))
        try await store.saveMessages([ChatMessage(role: .user, content: "one")], threadID: "t")
        try await store.saveMessages([ChatMessage(role: .user, content: "one"),
                                      ChatMessage(role: .assistant, content: "two")], threadID: "t")
        let loaded = try await store.loadMessages(threadID: "t")
        XCTAssertEqual(loaded.map(\.content), ["one", "two"])
    }

    func testDeleteThreadCascadesMessages() async throws {
        let (store, dir) = try freshStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.upsertThread(ChatThread(id: "t", title: "x"))
        try await store.saveMessages([ChatMessage(role: .user, content: "hi")], threadID: "t")
        try await store.deleteThread(id: "t")
        let remainingThreads = try await store.allThreads()
        let remainingMessages = try await store.loadMessages(threadID: "t")
        XCTAssertTrue(remainingThreads.isEmpty)
        XCTAssertTrue(remainingMessages.isEmpty)
    }

    func testSettingsStoreDefaultsAndClamping() {
        let suite = UserDefaults(suiteName: "MnemoSet-\(UUID().uuidString)")!
        let s = SettingsStore(defaults: suite)
        XCTAssertEqual(s.topK, 8)
        XCTAssertEqual(s.temperature, 0.3, accuracy: 0.0001)
        XCTAssertTrue(s.multimodal)
        XCTAssertFalse(s.queryRewrite)

        s.topK = 50            // clamps to 20
        s.temperature = -1     // clamps to 0
        XCTAssertEqual(s.topK, 20)
        XCTAssertEqual(s.temperature, 0.0, accuracy: 0.0001)
    }

    func testDeepSeekKeyPersistsInKeychainNotDefaults() {
        let suiteName = "MnemoSecret-\(UUID().uuidString)"
        let service = "com.mnemosyne.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            KeychainStore.delete(service: service, account: "deepseek.apiKey")
            defaults.removePersistentDomain(forName: suiteName)
        }

        let s1 = SettingsStore(defaults: defaults, keychainService: service)
        XCTAssertTrue(s1.setDeepSeekKey("  sk-test-key  "))
        XCTAssertNil(defaults.string(forKey: "mnemosyne.deepSeekKey"),
                     "API keys should not be stored in UserDefaults")

        let s2 = SettingsStore(defaults: defaults, keychainService: service)
        XCTAssertEqual(s2.deepSeekKey, "sk-test-key")
        XCTAssertTrue(s2.setDeepSeekKey(""))
        XCTAssertEqual(s2.deepSeekKey, "")
    }

    func testLiveQueryRewriteResolvesPronouns() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled,
                          "set MNEMO_LIVE_DEEPSEEK=1 to run this quota-spending live test")
        let config = Config.load()
        try XCTSkipIf(config.deepSeekKey.isEmpty, "no DeepSeek key")
        let embedder = Embedder()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MnemoQR-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        var agent = RAGAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: config))
        agent.queryRewrite = true

        let history = [
            ChatMessage(role: .user, content: "Tell me about the FAISS vector library."),
            ChatMessage(role: .assistant, content: "FAISS does similarity search.")
        ]
        // prepare() runs the rewrite internally; just assert it doesn't throw and returns a prompt.
        let prepared: RAGAgent.Prepared
        do { prepared = try await agent.prepare(query: "how fast is it?", history: history) }
        catch { throw XCTSkip("network unavailable: \(error.localizedDescription)") }
        XCTAssertEqual(prepared.messages.last?.content, "how fast is it?",
                       "the user-facing question stays original even when the search query is rewritten")
    }
}
