import SwiftUI

/// A dashboard of what's in the knowledge base — counts, size, kind breakdown.
struct InsightsView: View {
    let store: KnowledgeStore
    @State private var stats: KnowledgeStats = .empty
    @State private var loaded = false

    private let cardColumns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: DS.Space.x4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                SectionHeader("Insights", subtitle: "Your knowledge base at a glance")

                LazyVGrid(columns: cardColumns, spacing: DS.Space.x4) {
                    StatCard(value: "\(stats.itemCount)", label: "Items", icon: "doc.on.doc")
                    StatCard(value: "\(stats.chunkCount)", label: "Chunks", icon: "square.stack.3d.up")
                    StatCard(value: Format.bytes(stats.totalBytes), label: "Indexed", icon: "internaldrive")
                    StatCard(value: "\(stats.threadCount)", label: "Chats", icon: "bubble.left.and.text.bubble.right")
                    StatCard(value: "\(stats.tagCount)", label: "Tags", icon: "tag")
                }

                if stats.activity.contains(where: { $0 > 0 }) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: DS.Space.x3) {
                            HStack {
                                Text("Activity").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                                Spacer()
                                Text("last \(stats.activity.count) days").font(DS.Typo.caption)
                                    .foregroundStyle(DS.ColorToken.textTertiary)
                            }
                            Sparkline(values: stats.activity, height: 54)
                            Text("\(stats.activity.reduce(0, +)) items added/changed recently")
                                .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                        }
                        .padding(DS.Space.x6)
                    }
                }

                if !stats.byKind.isEmpty {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: DS.Space.x3) {
                            Text("By type").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            ForEach(stats.byKind, id: \.kind) { entry in
                                StatBar(label: entry.kind.rawValue, icon: entry.kind.sfSymbol,
                                        count: entry.count,
                                        fraction: Double(entry.count) / Double(stats.maxKindCount))
                            }
                        }
                        .padding(DS.Space.x6)
                    }
                }

                if !stats.topCited.isEmpty {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: DS.Space.x3) {
                            Text("Most referenced").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            ForEach(stats.topCited, id: \.item.id) { entry in
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.item.path)])
                                } label: {
                                    HStack(spacing: DS.Space.x2) {
                                        Image(systemName: entry.item.kind.sfSymbol).font(.system(size: 12))
                                            .foregroundStyle(DS.ColorToken.provenance)
                                        Text(entry.item.title).font(DS.Typo.callout)
                                            .foregroundStyle(DS.ColorToken.textSecondary).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(entry.count)×").font(DS.Typo.caption)
                                            .foregroundStyle(DS.ColorToken.textTertiary)
                                    }
                                }
                                .buttonStyle(.plain).help("Reveal \(entry.item.path)")
                            }
                        }
                        .padding(DS.Space.x6)
                    }
                }

                if let oldest = stats.oldest, let newest = stats.newest {
                    Text("Spanning \(Format.ago(oldest)) → \(Format.ago(newest))")
                        .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
                }

                if loaded && stats.itemCount == 0 {
                    Text("Ingest a folder to see insights here.")
                        .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textTertiary)
                }
            }
            .padding(DS.Space.x8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
        .task {
            stats = (try? await store.stats()) ?? .empty
            withAnimation(DS.Motion.smooth) { loaded = true }
        }
    }
}
