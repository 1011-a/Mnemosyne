import Foundation

/// A deferred task the agent set for itself or the user — a persistent TODO the
/// Ask tab can act on later ("remind me to…", "follow up on…"). Not an alarm:
/// there's no background scheduler, so `due` is a human note ("tomorrow",
/// "2026-07-01"), and the list is surfaced in the UI and to the agent.
struct Reminder: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var due: String?      // freeform human due ("tomorrow", "Fri", "2026-07-01")
    var done: Bool
    let createdAt: Date
}

/// File-backed list of `Reminder`s (JSON). Pure value type with an injectable
/// path so tests run against a temp file. Newest-open-first ordering.
struct ReminderStore: Sendable {
    let path: String

    init(path: String = ReminderStore.defaultPath) { self.path = path }

    static var defaultPath: String { NSHomeDirectory() + "/Documents/Mnemosyne/reminders.json" }

    /// All reminders: open ones first (newest created first), then completed.
    func all() -> [Reminder] {
        let items = load()
        let open = items.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt }
        let done = items.filter { $0.done }.sorted { $0.createdAt > $1.createdAt }
        return open + done
    }

    /// Add a new open reminder and persist. `idSeed` makes ids deterministic in
    /// tests; production passes a UUID.
    @discardableResult
    func add(title: String, due: String? = nil, now: Date = Date(),
             idSeed: String = UUID().uuidString) -> Reminder {
        var items = load()
        let r = Reminder(id: idSeed, title: title, due: due, done: false, createdAt: now)
        items.append(r)
        save(items)
        return r
    }

    /// Mark the first reminder matching `ref` (id, exact title, then substring)
    /// as done. Returns the updated reminder, or nil if nothing matched.
    @discardableResult
    func complete(matching ref: String) -> Reminder? {
        var items = load()
        guard let idx = matchIndex(ref, in: items) else { return nil }
        items[idx].done = true
        save(items)
        return items[idx]
    }

    /// Set the done-state of the first reminder matching `ref` (lets the UI toggle
    /// a task back to open). Returns the updated reminder, or nil if none matched.
    @discardableResult
    func setDone(matching ref: String, to done: Bool) -> Reminder? {
        var items = load()
        guard let idx = matchIndex(ref, in: items) else { return nil }
        items[idx].done = done
        save(items)
        return items[idx]
    }

    /// Delete the first reminder matching `ref`. Returns true if one was removed.
    @discardableResult
    func remove(matching ref: String) -> Bool {
        var items = load()
        guard let idx = matchIndex(ref, in: items) else { return false }
        items.remove(at: idx)
        save(items)
        return true
    }

    /// Index of the best match: exact id → exact title → title substring (open
    /// reminders preferred over completed ones).
    static func matchIndex(_ ref: String, in items: [Reminder]) -> Int? {
        let key = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let i = items.firstIndex(where: { $0.id.lowercased() == key }) { return i }
        if let i = items.firstIndex(where: { !$0.done && $0.title.lowercased() == key }) { return i }
        if let i = items.firstIndex(where: { $0.title.lowercased() == key }) { return i }
        if let i = items.firstIndex(where: { !$0.done && $0.title.lowercased().contains(key) }) { return i }
        return items.firstIndex(where: { $0.title.lowercased().contains(key) })
    }
    private func matchIndex(_ ref: String, in items: [Reminder]) -> Int? { Self.matchIndex(ref, in: items) }

    // MARK: persistence
    private func load() -> [Reminder] {
        guard let data = FileManager.default.contents(atPath: path),
              let items = try? JSONDecoder.reminders.decode([Reminder].self, from: data) else { return [] }
        return items
    }
    private func save(_ items: [Reminder]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.reminders.encode(items) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

private extension JSONEncoder {
    static var reminders: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}
private extension JSONDecoder {
    static var reminders: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
