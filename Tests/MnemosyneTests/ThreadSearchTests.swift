import XCTest
@testable import Mnemosyne

final class ThreadSearchTests: XCTestCase {

    private func store() async throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TS-\(UUID().uuidString)")
        let s = try KnowledgeStore(directory: dir)
        try await s.upsertThread(ChatThread(id: "vec", title: "Vector databases"))
        try await s.saveMessages([
            ChatMessage(role: .user, content: "How do embeddings work?"),
            ChatMessage(role: .assistant, content: "They map text to numbers for FAISS search.")
        ], threadID: "vec")
        try await s.upsertThread(ChatThread(id: "cook", title: "Dinner ideas"))
        try await s.saveMessages([
            ChatMessage(role: .user, content: "Best risotto recipe?")
        ], threadID: "cook")
        return s
    }

    func testSearchByTitle() async throws {
        let s = try await store()
        let hits = try await s.searchThreads(query: "vector")
        XCTAssertEqual(hits.map(\.id), ["vec"])
    }

    func testSearchByMessageContent() async throws {
        let s = try await store()
        let hits = try await s.searchThreads(query: "FAISS")
        XCTAssertEqual(hits.map(\.id), ["vec"], "matches on message content")
        let hits2 = try await s.searchThreads(query: "risotto")
        XCTAssertEqual(hits2.map(\.id), ["cook"])
    }

    func testEmptyQueryReturnsAll() async throws {
        let s = try await store()
        let hits = try await s.searchThreads(query: "   ")
        XCTAssertEqual(Set(hits.map(\.id)), ["vec", "cook"])
    }

    func testNoMatch() async throws {
        let s = try await store()
        let hits = try await s.searchThreads(query: "quantum")
        XCTAssertTrue(hits.isEmpty)
    }

    func testWildcardCharIsLiteral() async throws {
        let s = try await store()
        // "%" should not match everything.
        let hits = try await s.searchThreads(query: "%")
        XCTAssertTrue(hits.isEmpty, "literal % matches nothing here, not all threads")
    }

    func testPinnedFirstInResults() async throws {
        let s = try await store()
        try await s.setThreadPinned(id: "cook", pinned: true)
        // both contain "e"? search a common token present in both titles/messages.
        let hits = try await s.searchThreads(query: "e")
        XCTAssertEqual(hits.first?.id, "cook", "pinned thread sorts first")
    }
}
