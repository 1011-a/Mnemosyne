import SwiftUI
import Observation

/// Main-actor state for the Tasks panel — a thin view over `ReminderStore`, the
/// same persistent list the agent writes to via add_reminder/complete_reminder.
@MainActor
@Observable
final class TasksViewModel {
    private let store: ReminderStore
    var reminders: [Reminder] = []
    var draft: String = ""

    init(store: ReminderStore = ReminderStore()) { self.store = store }

    var open: [Reminder] { reminders.filter { !$0.done } }
    var done: [Reminder] { reminders.filter { $0.done } }
    var openCount: Int { open.count }

    func reload() { reminders = store.all() }

    func addDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.add(title: t)
        draft = ""
        reload()
    }

    func toggle(_ r: Reminder) { store.setDone(matching: r.id, to: !r.done); reload() }
    func remove(_ r: Reminder) { store.remove(matching: r.id); reload() }
}

/// The Tasks tab: the agent's deferred-work list. Add tasks by hand or let the
/// agent set them ("remind me to…"); tap the circle to complete. Composed from DS.
struct TasksView: View {
    @Bindable var vm: TasksViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                SectionHeader("Tasks", subtitle: "Deferred work — yours and the agent's follow-ups")
                composer
                if vm.reminders.isEmpty {
                    empty
                } else {
                    section(title: "OPEN", rows: vm.open, emptyNote: "Nothing open — you're clear.")
                    if !vm.done.isEmpty { section(title: "DONE", rows: vm.done, emptyNote: "") }
                }
            }
            .padding(DS.Space.x8)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
        .onAppear { vm.reload() }
    }

    private var composer: some View {
        HStack(spacing: DS.Space.x3) {
            Image(systemName: "plus.circle").foregroundStyle(DS.ColorToken.iris)
            TextField("Add a task…", text: $vm.draft)
                .textFieldStyle(.plain).font(DS.Typo.body)
                .foregroundStyle(DS.ColorToken.textPrimary)
                .onSubmit { vm.addDraft() }
            if !vm.draft.isEmpty {
                DSButton("Add", icon: "return", kind: .primary) { vm.addDraft() }
            }
        }
        .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x3)
        .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault))
    }

    @ViewBuilder
    private func section(title: String, rows: [Reminder], emptyNote: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text(title).font(DS.Typo.caption).tracking(1.2).foregroundStyle(DS.ColorToken.textTertiary)
            if rows.isEmpty {
                Text(emptyNote).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { r in
                        row(r)
                        if r.id != rows.last?.id {
                            Rectangle().fill(DS.ColorToken.borderSubtle).frame(height: 1)
                        }
                    }
                }
                .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.ColorToken.borderDefault))
            }
        }
    }

    private func row(_ r: Reminder) -> some View {
        HStack(spacing: DS.Space.x3) {
            Button { withAnimation(DS.Motion.snappy) { vm.toggle(r) } } label: {
                Image(systemName: r.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(r.done ? DS.ColorToken.success : DS.ColorToken.textTertiary)
            }.buttonStyle(.plain).help(r.done ? "Reopen" : "Complete")

            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(DS.Typo.body)
                    .foregroundStyle(r.done ? DS.ColorToken.textTertiary : DS.ColorToken.textPrimary)
                    .strikethrough(r.done, color: DS.ColorToken.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let due = r.due, !due.isEmpty {
                    Text("due \(due)").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.iris)
                }
            }
            Spacer(minLength: 0)
            Button { withAnimation(DS.Motion.snappy) { vm.remove(r) } } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(DS.ColorToken.textTertiary)
            }.buttonStyle(.plain).help("Delete task")
        }
        .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x3)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text("No tasks yet.").font(DS.Typo.lead).foregroundStyle(DS.ColorToken.textSecondary)
            Text("Add one above, or ask the agent to \u{201C}remind me to follow up on X\u{201D} \u{2014} it'll appear here.")
                .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textTertiary)
        }
        .padding(DS.Space.x6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }
}
