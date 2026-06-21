import SwiftUI

/// A gallery of the deliverables the agent has built (HTML reports, dashboards,
/// visualizations, code). Completes the create_artifact loop: build → browse →
/// reopen / reveal / delete. Composed from DS tokens.
struct ArtifactsView: View {
    @State private var artifacts: [Artifact] = []
    @State private var confirmDelete: Artifact?
    @State private var thumbs: [String: NSImage] = [:]
    /// Path of the artifact whose Export button just succeeded (shows a brief check).
    @State private var exporting: String?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: DS.Space.x4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                SectionHeader("Artifacts", subtitle: "Things the agent has built from your knowledge")
                if artifacts.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: columns, spacing: DS.Space.x4) {
                        ForEach(artifacts) { card($0) }
                    }
                }
            }
            .padding(DS.Space.x8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
        .onAppear { artifacts = ArtifactStore.all() }
        .confirmationDialog("Delete this artifact and its files?", isPresented: deletePresented, presenting: confirmDelete) { a in
            Button("Delete", role: .destructive) { ArtifactStore.delete(a); artifacts = ArtifactStore.all() }
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    private func card(_ a: Artifact) -> some View {
        GlassPanel(radius: DS.Radius.lg) {
            VStack(alignment: .leading, spacing: DS.Space.x3) {
                // Preview: a rendered thumbnail for HTML artifacts, else a tinted icon panel.
                Group {
                    if let img = thumbs[a.path] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        DS.ColorToken.canvasRaised.overlay(
                            Image(systemName: icon(for: a)).font(.system(size: 30))
                                .foregroundStyle(DS.ColorToken.iris.opacity(0.7)))
                    }
                }
                .frame(height: 132).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.ColorToken.borderDefault))
                .task(id: a.path) { if thumbs[a.path] == nil { thumbs[a.path] = await ArtifactThumbnailer.shared.thumbnail(for: a) } }

                HStack(spacing: DS.Space.x2) {
                    Image(systemName: icon(for: a)).foregroundStyle(DS.ColorToken.iris)
                    Text(a.title).font(DS.Typo.title3).foregroundStyle(DS.ColorToken.textPrimary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Text(a.files.prefix(4).joined(separator: " · "))
                    .font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary).lineLimit(1)
                Text("\(a.files.count) file\(a.files.count == 1 ? "" : "s") · \(Format.ago(a.date))")
                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                HStack(spacing: DS.Space.x2) {
                    DSButton("Open", icon: "arrow.up.forward.app", kind: .primary) {
                        if let p = a.mainPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                    }
                    DSButton("Reveal", icon: "folder", kind: .secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)])
                    }
                    Spacer(minLength: 0)
                    Button { export(a) } label: {
                        Image(systemName: exporting == a.path ? "checkmark" : "square.and.arrow.up")
                            .font(.system(size: 12))
                            .foregroundStyle(exporting == a.path ? DS.ColorToken.success : DS.ColorToken.textTertiary)
                    }.buttonStyle(.plain).help("Export as .zip to Desktop")
                    Button { confirmDelete = a } label: {
                        Image(systemName: "trash").font(.system(size: 12))
                            .foregroundStyle(DS.ColorToken.textTertiary)
                    }.buttonStyle(.plain).help("Delete artifact")
                }
                .padding(.top, DS.Space.x1)
            }
        }
    }

    /// Zip the artifact to the Desktop, reveal it, and flash a brief confirmation.
    private func export(_ a: Artifact) {
        guard let zip = ArtifactStore.export(a) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: zip)])
        withAnimation(DS.Motion.snappy) { exporting = a.path }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { withAnimation(DS.Motion.snappy) { if exporting == a.path { exporting = nil } } }
        }
    }

    private func icon(for a: Artifact) -> String {
        guard let m = a.mainFile?.lowercased() else { return "doc" }
        if m.hasSuffix(".html") { return "safari" }
        if m.hasSuffix(".md") { return "doc.richtext" }
        if m.hasSuffix(".swift") || m.hasSuffix(".py") || m.hasSuffix(".js") { return "chevron.left.forwardslash.chevron.right" }
        if m.hasSuffix(".png") || m.hasSuffix(".svg") || m.hasSuffix(".jpg") { return "photo" }
        return "doc.text"
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            Text("Nothing built yet.").font(DS.Typo.lead).foregroundStyle(DS.ColorToken.textSecondary)
            Text("Ask the agent to build something — e.g. \u{201C}create an HTML dashboard of my notes\u{201D} — and it'll appear here.")
                .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textTertiary)
        }
        .padding(DS.Space.x6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }
}
