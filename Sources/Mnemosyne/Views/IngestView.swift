import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Point Mnemosyne at a folder and watch it absorb everything inside.
struct IngestView: View {
    let services: Services
    @Bindable var progress: IngestProgress
    /// Jump to Ask and run a query (suggested from what was ingested).
    var onAsk: (String) -> Void = { _ in }
    @State private var dropTargeted = false
    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var suggestions: [Suggestion] = []
    /// Throttle state for live suggestion refresh while files are landing.
    @State private var suggestionBucket = -1
    @State private var refreshingSuggestions = false
    /// Selected Live-activity scene (persisted in settings).
    @State private var activityTheme: LiveActivityTheme = .pixelCity
    /// Bumped when the custom backdrop image changes, to force a refresh.
    @State private var activityImageVersion = 0
    /// Drives the SwiftUI `.fileImporter` for picking a backdrop image. Using the native
    /// file importer instead of a hand-rolled `NSOpenPanel` — the latter proved unreliable in
    /// this bundle (hung with `begin`, crashed with `runModal`).
    @State private var showingImagePicker = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: DS.Space.x6) {
            SectionHeader("Ingest", subtitle: "Add a folder — or drag files & folders anywhere here")

            GlassPanel {
                VStack(alignment: .leading, spacing: DS.Space.x5) {
                    HStack(spacing: DS.Space.x5) {
                        ProgressRing(fraction: progress.fraction, size: 84, lineWidth: 9)
                        VStack(alignment: .leading, spacing: DS.Space.x2) {
                            Text(statusTitle).font(DS.Typo.title3)
                                .foregroundStyle(DS.ColorToken.textPrimary)
                            Text(statusDetail).font(DS.Typo.callout)
                                .foregroundStyle(DS.ColorToken.textTertiary).lineLimit(1)
                            HStack(spacing: DS.Space.x4) {
                                // Persisted hero figure — survives reopens.
                                stat("In knowledge base", progress.libraryItems, DS.ColorToken.iris)
                                Divider().frame(height: 22)
                                stat("Added this run", progress.added, DS.ColorToken.success)
                                stat("Unchanged", progress.skipped, DS.ColorToken.textTertiary)
                            }
                        }
                        Spacer()
                    }
                    HStack(spacing: DS.Space.x3) {
                        DSButton("Choose folder…", icon: "folder.badge.plus", kind: .primary,
                                 action: chooseFolder)
                            .accessibilityIdentifier("ingest.chooseFolder")
                        DSButton("Import bookmarks…", icon: "bookmark", kind: .secondary,
                                 action: chooseBookmarks)
                            .accessibilityIdentifier("ingest.importBookmarks")
                        engineStatusDot
                    }
                    if services.settings.visionEngine == .gemma, !ollamaStatus.isReady {
                        Text(ollamaStatus.detail(model: services.config.ollamaVisionModel,
                                                 baseURL: services.config.ollamaBaseURL))
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.danger)
                            .textSelection(.enabled)
                    }
                }
                .padding(DS.Space.x6)
            }

            VStack(alignment: .leading, spacing: DS.Space.x2) {
                HStack(spacing: DS.Space.x2) {
                    Circle().fill(progress.isRunning ? DS.ColorToken.success : DS.ColorToken.textTertiary)
                        .frame(width: 7, height: 7)
                    Text("Live activity").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    Spacer()
                    // Theme selector — choose the Live-activity scene.
                    Menu {
                        ForEach(LiveActivityTheme.allCases) { theme in
                            Button {
                                activityTheme = theme
                                services.settings.liveActivityTheme = theme
                                // Choosing Custom Image with none set yet → prompt right away.
                                if theme == .customImage, services.settings.liveActivityImagePath.isEmpty {
                                    showingImagePicker = true
                                }
                            } label: {
                                Label(theme.label, systemImage: activityTheme == theme ? "checkmark" : theme.icon)
                            }
                        }
                        if activityTheme == .customImage {
                            Divider()
                            Button { showingImagePicker = true } label: { Label("Choose image…", systemImage: "photo") }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: activityTheme.icon).font(.system(size: 10))
                            Text(activityTheme.label).font(DS.Typo.caption)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .foregroundStyle(DS.ColorToken.textSecondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Choose the live-activity scene")
                    Text(progress.isRunning ? "building…" : "idle").font(DS.Typo.mono)
                        .foregroundStyle(progress.isRunning ? DS.ColorToken.success : DS.ColorToken.textTertiary)
                }
                switch activityTheme {
                case .pixelCity: PixelCityView(progress: progress)
                case .starrySky: StarrySkyView(progress: progress)
                case .customImage:
                    CustomImageActivityView(progress: progress,
                                            imagePath: services.settings.liveActivityImagePath,
                                            onChoose: { showingImagePicker = true })
                        .id(activityImageVersion)
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    Text(progress.isRunning ? "EMERGING IDEAS" : "NOW TRY ASKING")
                        .font(DS.Typo.caption).tracking(1)
                        .foregroundStyle(progress.isRunning ? DS.ColorToken.iris : DS.ColorToken.textTertiary)
                        .animation(DS.Motion.snappy, value: progress.isRunning)
                    FlowLayout(spacing: DS.Space.x2) {
                        ForEach(suggestions) { s in
                            Button { onAsk(s.query) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: s.icon).font(.system(size: 11)).foregroundStyle(DS.ColorToken.iris)
                                    Text(s.title).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                                }
                                .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x2)
                                .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
                            }
                            .buttonStyle(.plain).help(s.query)
                        }
                    }
                }
            }
        }
        .padding(DS.Space.x8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .strokeBorder(DS.Gradient.intelligence, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(DS.Space.x4)
                    .overlay(Text("Drop to ingest").font(DS.Typo.title3)
                        .foregroundStyle(DS.ColorToken.textPrimary))
                    .background(DS.ColorToken.canvas.opacity(0.4))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            services.ingestDropped(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        // Keep the persisted "in knowledge base" count fresh: on open, and each
        // time a run completes (so it climbs as files finish indexing).
        .task {
            activityTheme = services.settings.liveActivityTheme
            await services.refreshLibraryCount()
            ollamaStatus = await services.refreshOllamaStatus()
            suggestions = await SuggestionEngine.suggestions(from: services.store, limit: 4)
        }
        .onChange(of: progress.phase) { _, phase in
            if phase == .done {
                Task {
                    await services.refreshLibraryCount()
                    suggestions = await SuggestionEngine.suggestions(from: services.store, limit: 4)
                }
            }
        }
        // LIVE: as files land, refresh the chips when the added-count crosses a new
        // bucket — so ideas emerge mid-ingest, throttled to avoid per-file churn.
        .onChange(of: progress.added) { _, added in
            guard SuggestionEngine.shouldRefreshLive(added: added, lastBucket: suggestionBucket,
                                                     running: progress.isRunning), !refreshingSuggestions
            else { return }
            suggestionBucket = SuggestionEngine.liveBucket(added: added)
            refreshingSuggestions = true
            Task {
                let fresh = await SuggestionEngine.suggestions(from: services.store, limit: 4)
                await MainActor.run {
                    withAnimation(DS.Motion.snappy) { suggestions = fresh }
                    refreshingSuggestions = false
                }
            }
        }
        .fileImporter(isPresented: $showingImagePicker,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            handlePickedImage(result)
        }
    }

    /// Reflects the ENGINE the user actually picked, not always Gemma.
    @ViewBuilder private var engineStatusDot: some View {
        switch services.settings.visionEngine {
        case .claudeCode:
            if ClaudeCodeClient.isAvailable {
                StatusDot(ok: true, label: "Claude Code ready for images & documents")
            } else {
                StatusDot(ok: false, label: "Claude CLI not found — text only")
            }
        case .codex:
            if CodexCliClient.isAvailable {
                StatusDot(ok: true, label: "Codex CLI ready for images & documents")
            } else {
                StatusDot(ok: false, label: "Codex CLI not found — text only")
            }
        case .gemma:
            StatusDot(ok: ollamaStatus.isReady,
                      label: ollamaStatus.label(model: services.config.ollamaVisionModel))
        }
    }

    private var statusTitle: String {
        switch progress.phase {
        case .idle:      return "Ready to ingest"
        case .scanning:  return "Scanning folder…"
        case .ingesting: return "Indexing \(fmt(progress.processed)) of \(fmt(progress.total))"
        case .done:      return "Up to date"
        case .failed:    return "Something went wrong"
        }
    }
    private var statusDetail: String {
        if case .failed(let m) = progress.phase { return m }
        if progress.phase == .scanning { return "Counting files…" }
        if progress.isRunning {
            // "Looking at image — Gemma… · sample.jpg" — the verb explains slow files.
            let file = progress.currentFile
            if !progress.activity.isEmpty, !file.isEmpty { return "\(progress.activity) · \(file)" }
            if !file.isEmpty { return file }
            return "\(fmt(progress.remaining)) to go"
        }
        if progress.phase == .done {
            let lib = "\(fmt(progress.libraryItems)) items in your knowledge base"
            return progress.added > 0 ? "\(progress.added) new · \(lib)" : lib
        }
        if progress.libraryItems > 0 { return "\(fmt(progress.libraryItems)) items in your knowledge base" }
        return "Pick a folder to begin"
    }

    /// Group digits so big counts read as "5,611" not "5611".
    private func fmt(_ n: Int) -> String {
        IngestView.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)").font(DS.Typo.bodyMed).foregroundStyle(color)
            Text(label).font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ingest"
        if panel.runModal() == .OK, let url = panel.url {
            services.ingest(folder: url)
        }
    }

    /// Handle the backdrop image picked via SwiftUI's native `.fileImporter`. Copies it into
    /// Application Support (so it persists even if the original moves) and switches to the theme.
    /// Uses the native importer rather than a hand-rolled `NSOpenPanel`, which proved unreliable
    /// in this bundle (hung with `begin`, crashed with `runModal`).
    private func handlePickedImage(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let src = urls.first else { return }
        // User-selected URLs are security-scoped; bracket the read access.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Mnemosyne")
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension
        let dest = URL(fileURLWithPath: dir).appendingPathComponent("activity-bg.\(ext)")
        try? fm.removeItem(at: dest)
        // Copy via Data so it works whether or not the source stays accessible.
        guard let data = try? Data(contentsOf: src), (try? data.write(to: dest)) != nil else { return }
        services.settings.liveActivityImagePath = dest.path
        services.settings.liveActivityTheme = .customImage
        activityTheme = .customImage
        activityImageVersion += 1
    }

    private func chooseBookmarks() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Safari Bookmarks.plist (in ~/Library/Safari)"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Safari")
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            services.importBookmarks(from: url)
        }
    }
}
