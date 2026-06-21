import SwiftUI
import AppKit

/// Detail sheet for one knowledge item: metadata, its extracted chunks, and
/// quick actions (reveal the source, or seed a chat about it).
struct ItemDetailView: View {
    let item: KnowledgeItem
    let store: KnowledgeStore
    var onAsk: (KnowledgeItem) -> Void
    /// Jump to Ask and run a free-text request about this file (summarize/outline/…).
    var onAskText: (String) -> Void = { _ in }
    var onReingest: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var chunks: [String] = []
    @State private var related: [KnowledgeItem] = []
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var preview: NSImage?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x5) {
            header
            tagEditor
            quickActions
            Divider().overlay(DS.ColorToken.borderSubtle)
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.x3) {
                        if !related.isEmpty {
                            Text("RELATED").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            ForEach(related) { rel in relatedRow(rel) }
                            Divider().overlay(DS.ColorToken.borderSubtle).padding(.vertical, DS.Space.x2)
                        }
                        Text("\(chunks.count) chunk\(chunks.count == 1 ? "" : "s")").font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.textTertiary)
                        ForEach(Array(chunks.enumerated()), id: \.offset) { i, text in
                            chunkRow(i + 1, text)
                        }
                    }
                }
            }
        }
        .padding(DS.Space.x6)
        .frame(width: 640, height: 560)
        .background(DS.ColorToken.surface)
        .task {
            chunks = (try? await store.chunkTexts(forItem: item.id)) ?? []
            related = ((try? await store.relatedItems(to: item.id, k: 4)) ?? []).map(\.item)
            tags = (try? await store.tags(forItem: item.id)) ?? []
            loading = false
            let path = item.path, kind = item.kind
            if let data = await Task.detached(priority: .utility, operation: {
                PreviewLoader.previewPNG(for: URL(fileURLWithPath: path), kind: kind)
            }).value {
                preview = NSImage(data: data)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.x3) {
            if let preview {
                Image(nsImage: preview)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
            } else {
                Image(systemName: item.kind.sfSymbol)
                    .font(.system(size: 22)).foregroundStyle(DS.ColorToken.iris)
                    .frame(width: 36, height: 36)
                    .background(DS.ColorToken.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(DS.Typo.title2).foregroundStyle(DS.ColorToken.textPrimary)
                    .lineLimit(1)
                Text(item.path).font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(item.kind.rawValue) · \(Format.bytes(item.byteSize)) · \(Format.ago(item.modifiedAt))")
                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: DS.Space.x2) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.ColorToken.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(DS.ColorToken.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("detail.close")
                .help("Close")
                DSButton("Ask about this", icon: "sparkles", kind: .primary) {
                    onAsk(item); dismiss()
                }
                if let webURL = item.webURL {
                    DSButton("Open in browser", icon: "safari", kind: .secondary) {
                        NSWorkspace.shared.open(webURL); dismiss()
                    }
                    .accessibilityIdentifier("detail.openInBrowser")
                } else {
                    DSButton("Reveal in Finder", icon: "folder", kind: .secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                    DSButton("Re-ingest", icon: "arrow.clockwise", kind: .ghost) {
                        onReingest(item.path); dismiss()
                    }
                }
            }
        }
    }

    /// One-tap document actions that route to the agent's per-file tools.
    private var quickActions: some View {
        HStack(spacing: DS.Space.x2) {
            quickAction("Summarize", "text.alignleft", "Summarize the file \u{201C}\(item.title)\u{201D} using summarize_item.")
            quickAction("Outline", "list.bullet.indent", "Show the outline of \u{201C}\(item.title)\u{201D} using outline_item.")
            quickAction("Key terms", "tag", "What are the key terms in \u{201C}\(item.title)\u{201D}? Use keyword_extract, then suggest 3-5 labels.")
            quickAction("Auto-label", "wand.and.stars", "Suggest labels for \u{201C}\(item.title)\u{201D} using suggest_labels, then ask me before applying.")
            quickAction("Translate", "character.bubble", "Translate the file \u{201C}\(item.title)\u{201D} with translate_item — into English, or into 中文 if it's already English.")
            Spacer(minLength: 0)
        }
    }

    private func quickAction(_ label: String, _ icon: String, _ prompt: String) -> some View {
        Button { onAskText(prompt); dismiss() } label: {
            HStack(spacing: DS.Space.x1) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(DS.Typo.caption)
            }
            .foregroundStyle(DS.ColorToken.iris)
            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
            .overlay(Capsule().strokeBorder(DS.ColorToken.iris.opacity(0.35), lineWidth: 1))
        }.buttonStyle(.plain).help(prompt)
    }

    private var tagEditor: some View {
        HStack(spacing: DS.Space.x2) {
            Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(DS.ColorToken.textTertiary)
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: DS.Space.x1) {
                    Text(tag).font(DS.Typo.caption)
                    Button { remove(tag) } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(DS.ColorToken.iris)
                .padding(.horizontal, DS.Space.x2).padding(.vertical, DS.Space.x1)
                .background(DS.ColorToken.iris.opacity(0.12), in: Capsule())
            }
            TextField("Add tag…", text: $newTag)
                .textFieldStyle(.plain).font(DS.Typo.caption)
                .foregroundStyle(DS.ColorToken.textPrimary)
                .frame(width: 90)
                .onSubmit(addTag)
            Spacer()
        }
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        newTag = ""
        guard !t.isEmpty, !tags.contains(t) else { return }
        tags.append(t); tags.sort()
        persistTags()
    }
    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
        persistTags()
    }
    private func persistTags() {
        let snapshot = tags, id = item.id
        Task { try? await store.setTags(snapshot, forItem: id) }
    }

    private func relatedRow(_ rel: KnowledgeItem) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rel.path)])
        } label: {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: rel.kind.sfSymbol).font(.system(size: 12))
                    .foregroundStyle(DS.ColorToken.iris)
                Text(rel.title).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                    .foregroundStyle(DS.ColorToken.textTertiary)
            }
            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
            .background(DS.ColorToken.canvasRaised,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain).help("Reveal \(rel.path) in Finder")
    }

    private func chunkRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.x3) {
            Text("\(n)").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.provenance)
                .frame(width: 22, alignment: .trailing)
            Text(text).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.x3)
        .background(DS.ColorToken.canvasRaised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }
}
