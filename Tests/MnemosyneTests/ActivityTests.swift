import XCTest
@testable import Mnemosyne

final class ActivityTests: XCTestCase {

    func testIngestActivityBucketsByDay() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)

        func add(_ id: String, daysAgo: Double) async throws {
            let date = Date(timeIntervalSinceNow: -daysAgo * 86_400 - 3_600) // mid-bucket
            try await store.upsert(
                item: KnowledgeItem(id: id, path: "/tmp/\(id)", title: id, kind: .text,
                                    contentHash: id, byteSize: 0, createdAt: date, modifiedAt: date),
                chunks: [])
        }
        try await add("today", daysAgo: 0)
        try await add("today2", daysAgo: 0)
        try await add("twoDays", daysAgo: 2)
        try await add("longAgo", daysAgo: 40)  // outside the 7-day window below

        let activity = try await store.ingestActivity(days: 7)
        XCTAssertEqual(activity.count, 7)
        XCTAssertEqual(activity.last, 2, "today bucket (last index) has 2 items")
        XCTAssertEqual(activity[activity.count - 3], 1, "2-days-ago bucket has 1 item")
        XCTAssertEqual(activity.reduce(0, +), 3, "the 40-day-old item is outside the window")
    }

    func testEmptyActivityAllZeros() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Activity0-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        let activity = try await store.ingestActivity(days: 30)
        XCTAssertEqual(activity, Array(repeating: 0, count: 30))
    }

    func testStatsIncludesActivity() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("StatsAct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        try await store.upsert(
            item: KnowledgeItem(id: "a", path: "/tmp/a", title: "a", kind: .text,
                                contentHash: "a", byteSize: 0, createdAt: Date(), modifiedAt: Date()),
            chunks: [])
        let stats = try await store.stats()
        XCTAssertEqual(stats.activity.count, 30)
        XCTAssertEqual(stats.activity.last, 1)
    }
}
