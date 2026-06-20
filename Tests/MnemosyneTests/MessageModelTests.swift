import XCTest
@testable import Mnemosyne

final class MessageModelTests: XCTestCase {

    func testMessageModelPersistsRoundtrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MsgModel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        try await store.upsertThread(ChatThread(id: "t", title: "T"))

        let msgs = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "hi", citations: [], model: "deepseek-reasoner")
        ]
        try await store.saveMessages(msgs, threadID: "t")

        let loaded = try await store.loadMessages(threadID: "t")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].model, "", "user turns carry no model")
        XCTAssertEqual(loaded[1].model, "deepseek-reasoner", "assistant turn keeps its model")
    }

    func testDefaultModelEmpty() {
        XCTAssertEqual(ChatMessage(role: .user, content: "x").model, "")
    }
}
