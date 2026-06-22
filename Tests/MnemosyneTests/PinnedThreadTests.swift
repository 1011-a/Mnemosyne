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

    func testThreadSummaryRoundTripAndUpdate() async throws {
        let store = try freshStore()
        try await store.upsertThread(ChatThread(id: "t", title: "T"))
        // Nothing stored yet.
        let none = try await store.loadThreadSummary(threadID: "t")
        XCTAssertNil(none)
        // Save a summary covering the first 4 messages.
        try await store.saveThreadSummary(threadID: "t", boundary: 4, summary: "Discussed vectors.")
        let got = try await store.loadThreadSummary(threadID: "t")
        XCTAssertEqual(got?.boundary, 4)
        XCTAssertEqual(got?.summary, "Discussed vectors.")
        // Re-save (incremental advance) replaces it.
        try await store.saveThreadSummary(threadID: "t", boundary: 8, summary: "…and embeddings.")
        let updated = try await store.loadThreadSummary(threadID: "t")
        XCTAssertEqual(updated?.boundary, 8)
        XCTAssertEqual(updated?.summary, "…and embeddings.")
        // Forget clears it.
        try await store.deleteThreadSummary(threadID: "t")
        let after = try await store.loadThreadSummary(threadID: "t")
        XCTAssertNil(after, "deleted summary is gone")
    }

    func testPinnedFactsAddDedupeListRemove() async throws {
        let store = try freshStore()
        try await store.addPinnedFact("User's name is Sam", idSeed: "a")
        try await store.addPinnedFact("  user's name is sam  ", idSeed: "b")   // dup (case/space)
        try await store.addPinnedFact("Prefers metric", idSeed: "c")
        let facts = try await store.allPinnedFacts()
        XCTAssertEqual(facts.map(\.fact), ["User's name is Sam", "Prefers metric"], "dedup; oldest first")
        try await store.removePinnedFact(id: "a")
        let after = try await store.allPinnedFacts()
        XCTAssertEqual(after.map(\.fact), ["Prefers metric"])
    }

    func testPinnedFactsSurviveReopen() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Pin3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do { let s = try KnowledgeStore(directory: dir); try await s.addPinnedFact("Remember this", idSeed: "x") }
        let store2 = try KnowledgeStore(directory: dir)
        let reopened = try await store2.allPinnedFacts()
        XCTAssertEqual(reopened.map(\.fact), ["Remember this"], "pinned facts persist across launches")
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
