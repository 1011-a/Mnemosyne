import XCTest
@testable import Mnemosyne

final class ReasoningTests: XCTestCase {

    func testReasoningPersistsRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reason-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        try await store.upsertThread(ChatThread(id: "t", title: "T"))

        let msgs = [
            ChatMessage(role: .user, content: "why?"),
            ChatMessage(role: .assistant, content: "Because [1].", citations: [],
                        model: "deepseek-reasoner", reasoning: "Let me think step by step...")
        ]
        try await store.saveMessages(msgs, threadID: "t")

        let loaded = try await store.loadMessages(threadID: "t")
        XCTAssertEqual(loaded[1].reasoning, "Let me think step by step...")
        XCTAssertEqual(loaded[0].reasoning, "", "user turn has no reasoning")
    }

    func testDefaultReasoningEmpty() {
        XCTAssertEqual(ChatMessage(role: .assistant, content: "x").reasoning, "")
    }
}
