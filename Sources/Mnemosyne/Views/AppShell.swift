import SwiftUI

/// The app's main two-pane shell: NavRail + active section. Everything here is
/// composed from the Mnemosyne design system.
struct AppShell: View {
    let services: Services
    @State private var section = "chat"
    @State private var chat: ChatViewModel
    @State private var library: LibraryViewModel
    @State private var tasks = TasksViewModel()

    init(services: Services) {
        self.services = services
        _chat = State(initialValue: services.makeChat())
        _library = State(initialValue: LibraryViewModel(store: services.store))
    }

    @State private var showHistory = false
    @State private var searchFocusToken = 0

    private let nav: [(id: String, label: String)] = [
        ("chat", "Ask"), ("library", "Library"), ("ingest", "Ingest"),
        ("artifacts", "Artifacts"), ("tasks", "Tasks"), ("insights", "Insights"), ("settings", "Settings")
    ]

    var body: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.ColorToken.canvas.ignoresSafeArea())
            .navigationTitle("Mnemosyne")
            .toolbar { nativeToolbar }
        .onReceive(NotificationCenter.default.publisher(for: .mnemoNewChat)) { _ in
            chat.newThread(); withAnimation(DS.Motion.snappy) { section = "chat" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mnemoSelectSection)) { note in
            if let id = note.userInfo?["section"] as? String {
                withAnimation(DS.Motion.snappy) { section = id }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mnemoFocusSearch)) { _ in
            withAnimation(DS.Motion.snappy) { section = "library" }
            searchFocusToken += 1
        }
        // Refresh the task list/badge whenever the user changes pages — the agent
        // may have added or completed reminders during a chat turn.
        .onChange(of: section) { _, _ in tasks.reload() }
        .task {
            // Deterministic, network-free state when driven by XCUITest.
            if ProcessInfo.processInfo.arguments.contains("--uitest") {
                chat.loadUITestFixture()
                await services.seedUITestLibrary()
                library.reload()
                return
            }
            chat.resumeMostRecent()
            library.loadSavedSearches()
            tasks.reload()
            await services.probe()
            services.resumeIndexing()
        }
    }

    // Native window toolbar: section nav in the centre, chat actions on the right.
    @ToolbarContentBuilder
    private var nativeToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: DS.Space.x5) {
                ForEach(nav, id: \.id) { navButton($0) }
            }
        }
        if section == "chat" {
            ToolbarItemGroup(placement: .primaryAction) {
                if !chat.messages.isEmpty {
                    Button {
                        SavePanel.writeText(chat.exportMarkdown(),
                                            suggestedName: "\(chat.title).md", types: [.plainText])
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Export conversation")
                }
                Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Chat history")
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyPopover }
                Button { chat.newThread() } label: { Image(systemName: "square.and.pencil") }
                    .help("New chat")
            }
        }
    }

    private func navButton(_ item: (id: String, label: String)) -> some View {
        let active = section == item.id
        return Button { withAnimation(DS.Motion.snappy) { section = item.id } } label: {
            HStack(spacing: 4) {
                Text(item.label.uppercased()).font(DS.Typo.caption).tracking(0.8)
                    .foregroundStyle(active ? DS.ColorToken.iris : DS.ColorToken.textSecondary)
                if item.id == "tasks", tasks.openCount > 0 {
                    Text("\(tasks.openCount)").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DS.ColorToken.iris, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nav.\(item.id)")
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chat.threads.prefix(12)) { thread in
                Button { chat.open(thread); showHistory = false } label: {
                    HStack {
                        Text(thread.title).font(DS.Typo.body).lineLimit(1)
                            .foregroundStyle(DS.ColorToken.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x3)
                    .frame(width: 280, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if chat.threads.isEmpty {
                Text("No conversations yet").font(DS.Typo.callout)
                    .foregroundStyle(DS.ColorToken.textTertiary)
                    .padding(DS.Space.x4)
            }
        }
        .padding(.vertical, DS.Space.x2)
        .background(DS.ColorToken.surface)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case "chat":     ChatView(vm: chat, onIngest: goToIngest)
        case "library":  LibraryView(vm: library, store: services.store, onAsk: ask(about:),
                                     onAskText: { q in withAnimation(DS.Motion.snappy) { section = "chat" }; chat.send(q) },
                                     onIngest: goToIngest, onReingest: { services.reingest(path: $0) },
                                     focusToken: searchFocusToken)
        case "ingest":   IngestView(services: services, progress: services.progress,
                                     onAsk: { q in withAnimation(DS.Motion.snappy) { section = "chat" }; chat.send(q) })
        case "artifacts": ArtifactsView()
        case "tasks":    TasksView(vm: tasks)
        case "insights": InsightsView(store: services.store, onSelectTag: { tag in
                            library.activeTag = tag
                            withAnimation(DS.Motion.snappy) { section = "library" }
                         }, onAskText: { q in
                            withAnimation(DS.Motion.snappy) { section = "chat" }; chat.send(q)
                         })
        default:         SettingsView(services: services)
        }
    }

    private func goToIngest() { withAnimation(DS.Motion.snappy) { section = "ingest" } }

    /// Jump to chat and ask a grounded question about a specific item.
    private func ask(about item: KnowledgeItem) {
        withAnimation(DS.Motion.snappy) { section = "chat" }
        chat.send("What does my knowledge base say about \"\(item.title)\"? Summarize the key points with citations.")
    }
}

/// Boot screen → builds `Services`, then shows the shell (or an error).
struct ContentRoot: View {
    @State private var services: Services?
    @State private var bootError: String?

    var body: some View {
        Group {
            if let services {
                AppShell(services: services)
            } else if let bootError {
                bootErrorView(bootError)
            } else {
                launching.task { boot() }
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .preferredColorScheme(.light)
        // One accent everywhere: recolor every system control (focus rings, menus,
        // pickers, selections) to the vermilion instead of macOS blue.
        .tint(DS.ColorToken.iris)
    }

    private func boot() {
        do { services = try Services() }
        catch { bootError = error.localizedDescription }
    }

    private var launching: some View {
        ZStack {
            DS.ColorToken.canvas.ignoresSafeArea()
            HStack(spacing: DS.Space.x2) {
                Circle().fill(DS.ColorToken.iris).frame(width: 9, height: 9)
                Text("Mnemosyne").font(DS.Typo.title1).tracking(-0.5)
                    .foregroundStyle(DS.ColorToken.textPrimary)
            }
        }
    }

    private func bootErrorView(_ message: String) -> some View {
        ZStack {
            DS.ColorToken.canvas.ignoresSafeArea()
            VStack(spacing: DS.Space.x3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36)).foregroundStyle(DS.ColorToken.warning)
                Text("Couldn't start").font(DS.Typo.title2).foregroundStyle(DS.ColorToken.textPrimary)
                Text(message).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
            }
        }
    }
}

