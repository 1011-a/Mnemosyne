import XCTest
@testable import Mnemosyne

final class ReminderStoreTests: XCTestCase {

    private func tempStore() throws -> ReminderStore {
        let dir = try TestSupport.tempDirectory(prefix: "Reminders")
        return ReminderStore(path: dir.appendingPathComponent("reminders.json").path)
    }

    func testDueSoonFiltersDatedAndSortsEarliestFirst() {
        let now = ToolAgent.parseISODate("2026-06-15")!
        func r(_ id: String, _ title: String, due: String?, done: Bool = false) -> Reminder {
            Reminder(id: id, title: title, due: due, done: done, createdAt: now)
        }
        let reminders = [
            r("a", "overdue task", due: "2026-06-10"),       // past → included (overdue)
            r("b", "due in 3 days", due: "2026-06-18"),       // within 7d → included
            r("c", "far future", due: "2026-09-01"),          // beyond 7d → excluded
            r("d", "vague", due: "tomorrow"),                 // unparseable → excluded
            r("e", "no due", due: nil),                       // no due → excluded
            r("f", "done one", due: "2026-06-16", done: true), // done → excluded
        ]
        let due = ReminderStore.dueSoon(reminders, within: 7, now: now)
        XCTAssertEqual(due.map(\.id), ["a", "b"], "overdue + due-soon, earliest first; others excluded")
    }

    func testDueSoonEmptyWhenNothingDated() {
        let now = Date()
        let reminders = [Reminder(id: "x", title: "t", due: "someday", done: false, createdAt: now)]
        XCTAssertTrue(ReminderStore.dueSoon(reminders, within: 30, now: now).isEmpty)
        XCTAssertTrue(ReminderStore.dueSoon([], within: 7, now: now).isEmpty)
    }

    func testAddPersistsAndReloads() throws {
        let s = try tempStore()
        s.add(title: "Follow up on the budget", due: "tomorrow", idSeed: "r1")
        // A fresh store over the same path reads it back.
        let reloaded = ReminderStore(path: s.path).all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.title, "Follow up on the budget")
        XCTAssertEqual(reloaded.first?.due, "tomorrow")
        XCTAssertFalse(reloaded.first?.done ?? true)
    }

    func testOpenFirstOrdering() throws {
        let s = try tempStore()
        s.add(title: "first", now: Date(timeIntervalSince1970: 1), idSeed: "a")
        s.add(title: "second", now: Date(timeIntervalSince1970: 2), idSeed: "b")
        s.complete(matching: "second")
        let all = s.all()
        XCTAssertEqual(all.map(\.title), ["first", "second"], "open (first) before done (second)")
        XCTAssertEqual(all.last?.done, true)
    }

    func testCompleteBySubstringPrefersOpen() throws {
        let s = try tempStore()
        s.add(title: "ship the agent", idSeed: "x")
        let done = s.complete(matching: "ship")
        XCTAssertEqual(done?.id, "x")
        XCTAssertTrue(s.all().first { $0.id == "x" }?.done ?? false)
    }

    func testCompleteNoMatchReturnsNil() throws {
        let s = try tempStore()
        s.add(title: "real task", idSeed: "x")
        XCTAssertNil(s.complete(matching: "nonexistent"))
    }

    func testRemoveDeletesEntry() throws {
        let s = try tempStore()
        s.add(title: "temp", idSeed: "x")
        XCTAssertTrue(s.remove(matching: "temp"))
        XCTAssertTrue(s.all().isEmpty)
        XCTAssertFalse(s.remove(matching: "temp"), "second removal finds nothing")
    }

    func testSetDoneTogglesBothWays() throws {
        let s = try tempStore()
        s.add(title: "toggle me", idSeed: "x")
        XCTAssertEqual(s.setDone(matching: "x", to: true)?.done, true)
        XCTAssertTrue(s.all().first { $0.id == "x" }?.done ?? false)
        XCTAssertEqual(s.setDone(matching: "x", to: false)?.done, false, "can reopen a completed task")
        XCTAssertFalse(s.all().first { $0.id == "x" }?.done ?? true)
        XCTAssertNil(s.setDone(matching: "nope", to: true))
    }

    func testMatchIndexPrefersExactIdThenTitle() {
        let items = [
            Reminder(id: "id1", title: "alpha", due: nil, done: false, createdAt: Date()),
            Reminder(id: "id2", title: "id1", due: nil, done: false, createdAt: Date())
        ]
        XCTAssertEqual(ReminderStore.matchIndex("id1", in: items), 0, "exact id wins over a title that equals it")
        XCTAssertEqual(ReminderStore.matchIndex("alpha", in: items), 0)
        XCTAssertNil(ReminderStore.matchIndex("  ", in: items))
    }
}
