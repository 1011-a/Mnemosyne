import SwiftUI
import AppKit

/// Point Mnemosyne at a folder and watch it absorb everything inside.
struct IngestView: View {
    let services: Services
    @Bindable var progress: IngestProgress
    @State private var dropTargeted = false

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
                }
                .padding(DS.Space.x6)
            }

            VStack(alignment: .leading, spacing: DS.Space.x2) {
                HStack(spacing: DS.Space.x2) {
                    Circle().fill(progress.isRunning ? DS.ColorToken.success : DS.ColorToken.textTertiary)
                        .frame(width: 7, height: 7)
                    Text("Live activity").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    Spacer()
                    Text(progress.isRunning ? "building…" : "idle").font(DS.Typo.mono)
                        .foregroundStyle(progress.isRunning ? DS.ColorToken.success : DS.ColorToken.textTertiary)
                }
                PixelCityView(progress: progress)
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
        .task { await services.refreshLibraryCount() }
        .onChange(of: progress.phase) { _, phase in
            if phase == .done { Task { await services.refreshLibraryCount() } }
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
            if services.multimodalAvailable {
                StatusDot(ok: true, label: "Gemma 12B ready for images & PDFs")
            } else {
                StatusDot(ok: false, label: "Gemma offline — text only")
            }
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
