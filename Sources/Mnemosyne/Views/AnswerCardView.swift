import SwiftUI

/// The answer IS the interface. Instead of a flat chat bubble, an assistant turn
/// renders as a composed, luminous "answer card": a glowing lead summary, key
/// points, source tiles (with thumbnails), and actions. Light reveals meaning.
struct AnswerCardView: View {
    let message: ChatMessage
    var isLast: Bool
    var onCopy: () -> Void
    var onRegenerate: () -> Void
    var onReveal: (Citation) -> Void

    @State private var thumbs: [String: NSImage] = [:]
    @State private var hovered = false

    private var blocks: [AnswerBlock] { AnswerFormat.parse(message.content) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            header
            content
            if !message.citations.isEmpty { sources }
            actions
        }
        .padding(DS.Space.x6)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
        .overlay(alignment: .leading) {
            // A single precise accent rule on the left edge — the "answer" marker.
            Rectangle().fill(DS.ColorToken.iris).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: message.id) { await loadThumbnails() }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: DS.Space.x2) {
            Text("ANSWER").font(DS.Typo.caption).tracking(1.5)
                .foregroundStyle(DS.ColorToken.iris)
            Spacer()
            if !message.model.isEmpty {
                Text(message.model.uppercased()).font(DS.Typo.caption).tracking(0.6)
                    .foregroundStyle(DS.ColorToken.textTertiary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .lead(let t):
                    Text(CitationMarkup.attributed(t, accent: DS.ColorToken.iris)).font(DS.Typo.lead)
                        .foregroundStyle(DS.ColorToken.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .heading(let t):
                    Text(t.uppercased()).font(DS.Typo.caption).tracking(1.2)
                        .foregroundStyle(DS.ColorToken.textTertiary).padding(.top, DS.Space.x1)
                case .bullet(let t):
                    keyPoint(t)
                case .paragraph(let t):
                    Text(CitationMarkup.attributed(t, accent: DS.ColorToken.iris))
                        .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .table(let headers, let rows):
                    AnswerTableView(headers: headers, rows: rows)
                case .stats(let stats):
                    AnswerStatsView(stats: stats)
                case .quote(let q):
                    Text(CitationMarkup.attributed(q, accent: DS.ColorToken.iris))
                        .font(.system(size: 15, weight: .regular, design: .serif).italic())
                        .foregroundStyle(DS.ColorToken.textSecondary)
                        .lineSpacing(2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, DS.Space.x4).padding(.vertical, DS.Space.x1)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(DS.ColorToken.iris).frame(width: 3)
                        }
                case .code(let src):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(src).font(DS.Typo.mono)
                            .foregroundStyle(DS.ColorToken.textPrimary)
                            .textSelection(.enabled)
                            .padding(DS.Space.x4)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.ColorToken.canvasRaised,
                                in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(DS.ColorToken.borderSubtle, lineWidth: 1))
                }
            }
        }
    }

    private func keyPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.x3) {
            Rectangle().fill(DS.ColorToken.iris)
                .frame(width: 6, height: 6).padding(.top, 7)
            Text(CitationMarkup.attributed(text, accent: DS.ColorToken.iris))
                .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textSecondary)
                .lineSpacing(2)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text("SOURCES").font(DS.Typo.caption).tracking(1.2)
                .foregroundStyle(DS.ColorToken.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.x3) {
                    ForEach(message.citations) { c in
                        SourceTile(citation: c, thumb: thumbs[c.path]) { onReveal(c) }
                    }
                }
            }
        }
    }

    @State private var showCopied = false

    private var actions: some View {
        HStack(spacing: DS.Space.x2) {
            copyPill
            if isLast { pill("Regenerate", "arrow.clockwise", onRegenerate) }
        }
        .padding(.top, DS.Space.x1)
    }

    /// Copy with a brief "Copied ✓" confirmation so the silent action feels acknowledged.
    private var copyPill: some View {
        Button {
            onCopy()
            showCopied = true
            Task { try? await Task.sleep(nanoseconds: 1_400_000_000); showCopied = false }
        } label: {
            HStack(spacing: DS.Space.x1) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                Text(showCopied ? "Copied" : "Copy").font(DS.Typo.caption).tracking(0.4)
            }
            .foregroundStyle(showCopied ? DS.ColorToken.iris : DS.ColorToken.textSecondary)
            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
            .overlay(Capsule().strokeBorder(showCopied ? DS.ColorToken.iris.opacity(0.5)
                                            : DS.ColorToken.borderDefault, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.snappy, value: showCopied)
        .accessibilityIdentifier("answer.copy")
    }

    private func pill(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.x1) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(DS.Typo.caption).tracking(0.4)
            }
            .foregroundStyle(DS.ColorToken.textSecondary)
            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
            .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("answer.\(label.lowercased())")
    }

    private func loadThumbnails() async {
        for c in message.citations where thumbs[c.path] == nil {
            let url = URL(fileURLWithPath: c.path)
            guard let kind = TypeDetector.kind(for: url), kind == .image || kind == .pdf else { continue }
            if let data = await Task.detached(priority: .utility, operation: {
                PreviewLoader.previewPNG(for: url, kind: kind, maxDimension: 120)
            }).value, let img = NSImage(data: data) {
                thumbs[c.path] = img
            }
        }
    }
}

/// One source as a glowing tile (thumbnail or kind glyph + title + index).
private struct SourceTile: View {
    let citation: Citation
    let thumb: NSImage?
    var onTap: () -> Void
    @State private var hovered = false

    private var kind: ItemKind { TypeDetector.kind(for: URL(fileURLWithPath: citation.path)) ?? .unknown }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(DS.ColorToken.surfaceRaised)
                        .frame(height: 64)
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 64).clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    } else {
                        Image(systemName: kind.sfSymbol).font(.system(size: 20))
                            .foregroundStyle(DS.ColorToken.provenance)
                    }
                    // index badge
                    Text("\(citation.index)")
                        .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.canvas)
                        .frame(width: 16, height: 16).background(DS.ColorToken.provenance, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(DS.Space.x1)
                }
                Text(citation.title).font(DS.Typo.caption)
                    .foregroundStyle(DS.ColorToken.textSecondary).lineLimit(1)
                if !citation.snippetPreview.isEmpty {
                    Text(citation.snippetPreview).font(DS.Typo.caption)
                        .foregroundStyle(DS.ColorToken.textTertiary)
                        .lineLimit(2).lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: 152, alignment: .leading)
            .padding(DS.Space.x2)
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(DS.ColorToken.surfaceOverlay))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(hovered ? DS.ColorToken.provenance.opacity(0.6) : DS.ColorToken.borderSubtle, lineWidth: 1))
            .shadow(color: hovered ? DS.ColorToken.provenance.opacity(0.3) : .clear, radius: 12)
            .scaleEffect(hovered ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.snappy, value: hovered)
        .onHover { hovered = $0 }
        .help(citation.snippetPreview.isEmpty ? "Reveal \(citation.path)"
              : "\(citation.snippetPreview)\n\n\(citation.path)")
    }
}

/// Key metrics, rendered as a row of compact stat tiles (value over label) that
/// wraps to the card width — the generative "AI-OS" treatment for figures.
private struct AnswerStatsView: View {
    let stats: [AnswerStat]
    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 220), spacing: DS.Space.x3, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.x3) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: DS.Space.x1) {
                    Text(s.value).font(DS.Typo.statValue)
                        .foregroundStyle(DS.ColorToken.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(s.label.uppercased()).font(DS.Typo.caption).tracking(0.6)
                        .foregroundStyle(DS.ColorToken.textTertiary)
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.x4)
                .background(DS.ColorToken.canvasRaised,
                            in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(DS.ColorToken.iris)
                        .frame(width: 2.5).padding(.vertical, DS.Space.x3)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// Structured data, rendered as a precise Swiss mini-table: a quiet uppercase
/// header rule, hairline row separators, the first column emphasised as the label.
private struct AnswerTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.x5, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(h.uppercased()).font(DS.Typo.caption).tracking(0.8)
                        .foregroundStyle(DS.ColorToken.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DS.Space.x2)
                }
            }
            Divider().overlay(DS.ColorToken.borderDefault)
            ForEach(Array(rows.enumerated()), id: \.offset) { ri, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { ci, cell in
                        Text(cell)
                            .font(ci == 0 ? DS.Typo.callout.weight(.medium) : DS.Typo.callout)
                            .foregroundStyle(ci == 0 ? DS.ColorToken.textPrimary : DS.ColorToken.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, DS.Space.x3)
                    }
                }
                if ri < rows.count - 1 { Divider().overlay(DS.ColorToken.borderSubtle) }
            }
        }
        .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x2)
        .background(DS.ColorToken.canvasRaised,
                    in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.borderSubtle, lineWidth: 1))
        .textSelection(.enabled)
    }
}
