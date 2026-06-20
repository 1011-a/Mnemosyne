import XCTest
@testable import Mnemosyne

final class PinnedThreadTests: XCTestCase {

    private func freshStore() throws -> KnowledgeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Pin-\(UUID().uuidString)")
        return try KnowledgeStore(directory: dir)
    }

    func testPinnedThreadsFloatToTop() async throws {
        let store = try freshStore()
        // older (pinned) and newer (unpinned)
        try await store.upsertThread(ChatThread(id: "old", title: "Old",
            createdAt: Date(timeIntervalSinceNow: -1000), updatedAt: Date(timeIntervalSinceNow: -1000)))
        try await store.upsertThread(ChatThread(id: "new", title: "New",
            createdAt: Date(), updatedAt: Date()))

        // Without pins, newest first.
        var threads = try await store.allThreads()
        XCTAssertEqual(threads.map(\.id), ["new", "old"])

        // Pin the old one — it should jump to the top.
        try await store.setThreadPinned(id: "old", pinned: true)
        threads = try await store.allThreads()
        XCTAssertEqual(threads.map(\.id), ["old", "new"])
        XCTAssertTrue(threads.first?.pinned == true)
    }

    func testPinnedSurvivesReopen() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Pin2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try KnowledgeStore(directory: dir)
            try await store.upsertThread(ChatThread(id: "t", title: "Keep", pinned: true))
        }
        // Reopen the same DB file.
        let store2 = try KnowledgeStore(directory: dir)
        let threads = try await store2.allThreads()
        XCTAssertEqual(threads.first?.id, "t")
        XCTAssertTrue(threads.first?.pinned == true, "pinned state must persist across launches")
    }
}
