import Foundation

/// Persistent-memory tool handlers — long-term pinned facts and the reminder/task list — extracted
/// from `ToolAgent`'s main `handleTool` switch to keep that file focused. State-coupled (they read
/// and write the pinned-facts table and the `reminders` store), so they live in an `extension
/// ToolAgent` rather than migrating to Fathom. `handleMemoryTool` returns nil when `name` isn't one
/// of these, letting the caller fall through.
extension ToolAgent {
    func handleMemoryTool(_ name: String, args: String,
                          onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "pin_fact":
            guard let fact = arg("fact")?.trimmingCharacters(in: .whitespacesAndNewlines), !fact.isEmpty
            else { return ("Missing 'fact'.", []) }
            onStatus("Pinning to memory…")
            try? await store.addPinnedFact(fact)
            return ("Pinned to long-term memory — I'll always remember: “\(fact)”.", [])

        case "list_pinned_facts":
            onStatus("Reading long-term memory…")
            let facts = (try? await store.allPinnedFacts()) ?? []
            return facts.isEmpty ? ("Nothing pinned to long-term memory yet.", [])
                : ("Pinned facts:\n" + facts.map { "• \($0.fact)" }.joined(separator: "\n"), [])

        case "unpin_fact":
            guard let ref = arg("fact") else { return ("Missing 'fact'.", []) }
            onStatus("Updating long-term memory…")
            let facts = (try? await store.allPinnedFacts()) ?? []
            guard let id = Self.pinnedFactMatch(ref, in: facts) else {
                return facts.isEmpty ? ("No pinned facts to remove.", [])
                    : ("No pinned fact matches '\(ref)'. Pinned: \(facts.map(\.fact).joined(separator: "; ")).", [])
            }
            try? await store.removePinnedFact(id: id)
            return ("Unpinned that fact from long-term memory.", [])

        case "add_reminder":
            guard let title = arg("title") else { return ("Missing 'title'.", []) }
            onStatus("Setting a reminder: \(title)…")
            let r = reminders.add(title: title, due: arg("due"))
            let when = r.due.map { " (due \($0))" } ?? ""
            return ("Reminder set: “\(r.title)”\(when). I'll keep it in your task list.", [])

        case "list_reminders":
            onStatus("Reading your reminders…")
            let all = reminders.all()
            let open = all.filter { !$0.done }
            if all.isEmpty { return ("You have no reminders or deferred tasks.", []) }
            func line(_ r: Reminder) -> String {
                "\(r.done ? "✓" : "○") \(r.title)" + (r.due.map { " — due \($0)" } ?? "")
            }
            let openText = open.isEmpty ? "No open tasks." : open.map(line).joined(separator: "\n")
            let doneRecent = all.filter { $0.done }.prefix(3)
            let doneText = doneRecent.isEmpty ? "" : "\n\nRecently done:\n" + doneRecent.map(line).joined(separator: "\n")
            return ("Open tasks (\(open.count)):\n\(openText)\(doneText)", [])

        case "due_reminders":
            onStatus("Checking what's due…")
            let days = Int(arg("days") ?? "") ?? 7
            let now = Date()
            let due = ReminderStore.dueSoon(reminders.all(), within: days, now: now)
            guard !due.isEmpty else {
                return ("Nothing with a dated due in the next \(days) day(s). (Reminders with vague dues like 'tomorrow' aren't date-tracked.)", [])
            }
            func line(_ r: Reminder) -> String {
                let d = r.due.flatMap(DateExtractor.parse)
                let overdue = (d.map { $0 < now } ?? false) ? " ⚠️ OVERDUE" : ""
                return "○ \(r.title) — due \(r.due ?? "?")\(overdue)"
            }
            return ("\(due.count) reminder(s) due within \(days) day(s):\n" + due.map(line).joined(separator: "\n"), [])

        case "complete_reminder":
            guard let ref = arg("reminder") else { return ("Missing 'reminder'.", []) }
            onStatus("Completing reminder…")
            guard let r = reminders.complete(matching: ref) else {
                let open = reminders.all().filter { !$0.done }.map(\.title)
                return open.isEmpty ? ("No reminder matches '\(ref)' (your task list is empty).", [])
                    : ("No reminder matches '\(ref)'. Open tasks: \(open.joined(separator: "; ")).", [])
            }
            return ("Marked “\(r.title)” as done.", [])

        default:
            return nil
        }
    }
}
