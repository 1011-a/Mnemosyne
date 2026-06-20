import SwiftUI

/// The app's main two-pane shell: NavRail + active section. Everything here is
/// composed from the Mnemosyne design system.
struct AppShell: View {
    let services: Services
    @State private var section = "chat"
    @State private var chat: ChatViewModel
    @State private var library: LibraryViewModel

    init(services: Services) {
        self.services = services
        _chat = State(initialValue: services.makeChat())
        _library = State(initialValue: LibraryViewModel(store: services.store))
    }

    @State private var showHistory = false
    @State private var searchFocusToken = 0

    private let nav: [(id: String, label: String)] = [
        ("chat", "Ask"), ("library", "Library"), ("ingest", "Ingest"),
        ("insights", "Insights"), ("settings", "Settings")
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(DS.ColorToken.borderSubtle).frame(height: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.ColorToken.canvas.ignoresSafeArea())
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
            await services.probe()
            services.resumeIndexing()
        }
    }

    // A single, quiet top bar — wordmark, centered nav, minimal actions.
    private var topBar: some View {
        HStack(spacing: DS.Space.x4) {
            HStack(spacing: DS.Space.x2) {
                Circle().fill(DS.ColorToken.iris).frame(width: 7, height: 7)
                Text("Mnemosyne").font(DS.Typo.title3).tracking(0.3)
                    .foregroundStyle(DS.ColorToken.textPrimary)
            }
            Spacer()
            HStack(spacing: DS.Space.x6) {
                ForEach(nav, id: \.id) { item in
                    let active = section == item.id
                    Button { withAnimation(DS.Motion.snappy) { section = item.id } } label: {
                        Text(item.label.uppercased()).font(DS.Typo.caption).tracking(0.8)
                            .foregroundStyle(active ? DS.ColorToken.textPrimary : DS.ColorToken.textTertiary)
                            .overlay(alignment: .bottom) {
                                if active { Rectangle().fill(DS.ColorToken.iris).frame(height: 2).offset(y: 7) }
                            }
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("nav.\(item.id)")
                }
            }
            Spacer()
            HStack(spacing: DS.Space.x3) {
                if section == "chat" {
                    if !chat.messages.isEmpty {
                        barIcon("square.and.arrow.up", id: "chat.export") {
                            SavePanel.writeText(chat.exportMarkdown(),
                                                suggestedName: "\(chat.title).md", types: [.plainText])
                        }
                    }
                    barIcon("clock.arrow.circlepath", id: "chat.history") { showHistory.toggle() }
                        .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyPopover }
                    barIcon("square.and.pencil", id: "chat.newchat") { chat.newThread() }
                }
            }
        }
        // Pin a constant bar height so the top bar doesn't change height between
        // pages (only Chat shows the 30pt action icons; other pages have none).
        .frame(height: 30)
        .padding(.horizontal, DS.Space.x8).padding(.vertical, DS.Space.x4)
    }

    private func barIcon(_ icon: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14))
                .foregroundStyle(DS.ColorToken.textSecondary)
                .frame(width: 30, height: 30)
        }.buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .help(id)
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
                                     onIngest: goToIngest, onReingest: { services.reingest(path: $0) },
                                     focusToken: searchFocusToken)
        case "ingest":   IngestView(services: services, progress: services.progress)
        case "insights": InsightsView(store: services.store)
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
