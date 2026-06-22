import SwiftUI

/// Insights as "The Knowledge Ledger" — a Swiss data broadsheet (per the design
/// system's "Insights Editorial"): a masthead rule + meta, a 3-column lede with a
/// large serif hero figure (partial vermilion), two columns of body — composition
/// bars and an activity column chart + most-cited table — and a serif pull-quote.
struct InsightsView: View {
    let store: KnowledgeStore
    /// Tapping a constellation node asks the shell to filter the Library by that label.
    var onSelectTag: (String) -> Void = { _ in }
    /// Run a free-text agent request (the Health banner's one-tap fixes).
    var onAskText: (String) -> Void = { _ in }
    @State private var dismissedHealth = false

    private var nearDupClusters: [[String]] {
        TagCleanup.nearDuplicateClusters(TagStats.counts(tagLists).map { ($0.tag, $0.count) })
    }

    /// Dominant topics across the library (term + how many files mention it).
    private var themes: [(term: String, count: Int)] {
        KeywordExtractor.libraryThemes(docs: allItemsCache.map { "\($0.title) \($0.summary)" })
    }
    @State private var stats: KnowledgeStats = .empty
    @State private var allItemsCache: [KnowledgeItem] = []
    @State private var tagLists: [[String]] = []
    @State private var labelledCount = 0
    @State private var windowDays = 7
    @State private var loaded = false

    /// Top-label co-occurrence graph for the mini-viz (deterministic layout).
    private var tagGraph: TagGraph.Graph {
        TagGraph.build(counts: TagStats.counts(tagLists).map { ($0.tag, $0.count) },
                       pairs: TagStats.coOccurrences(tagLists, top: 40).map { ($0.a, $0.b, $0.count) })
    }

    /// Items changed within the chosen window, newest first (re-derived from cache).
    private var recent: [KnowledgeItem] {
        ToolAgent.changedSince(allItemsCache,
                               ToolAgent.changeThreshold(days: windowDays, since: nil, now: Date()))
    }

    private let subtle = DS.ColorToken.borderDefault.opacity(0.5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                subbar
                if loaded && !dismissedHealth, let banner = healthBanner { banner }
                lede
                bodyColumns
                if loaded && !themes.isEmpty { themesSection }
                if loaded && tagGraph.nodes.count >= 3 { tagGraphSection }
                if loaded && !allItemsCache.isEmpty { recentChanges }
                pullQuote
                if loaded && stats.itemCount == 0 {
                    Text("Ingest a folder to fill the ledger.")
                        .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textTertiary)
                        .padding(.top, DS.Space.x6)
                }
            }
            .padding(DS.Space.x8)
            .frame(maxWidth: 880, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)   // centre the ledger column
        }
        .background(Color.clear)
        .task {
            stats = (try? await store.stats()) ?? .empty
            allItemsCache = (try? await store.allItems()) ?? []
            let byItem = (try? await store.tagsByItem()) ?? [:]
            tagLists = Array(byItem.values)
            labelledCount = allItemsCache.filter { !(byItem[$0.id] ?? []).isEmpty }.count
            withAnimation(DS.Motion.smooth) { loaded = true }
        }
    }

    // MARK: masthead

    private var masthead: some View {
        HStack(alignment: .bottom) {
            Text("The Knowledge Ledger")
                .font(.system(size: 38, weight: .bold, design: .serif)).tracking(-0.5)
                .foregroundStyle(DS.ColorToken.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("MNEMOSYNE · INSIGHTS").font(DS.Typo.caption).tracking(0.8)
                Text("ON-DEVICE EDITION").font(DS.Typo.caption).tracking(0.8)
                    .foregroundStyle(DS.ColorToken.textPrimary)
            }
            .foregroundStyle(DS.ColorToken.textTertiary)
        }
        .padding(.bottom, DS.Space.x3)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.ColorToken.textPrimary).frame(height: 2) }
    }

    private var subbar: some View {
        HStack {
            Text("A STANDING ACCOUNT OF EVERYTHING YOU REMEMBER")
            Spacer()
            Text(spanText)
        }
        .font(DS.Typo.caption).tracking(1).foregroundStyle(DS.ColorToken.textTertiary)
        .padding(.vertical, DS.Space.x2)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.ColorToken.borderDefault).frame(height: 1) }
    }

    private var spanText: String {
        if let oldest = stats.oldest { return "SINCE \(Format.ago(oldest))".uppercased() }
        return "UPDATED JUST NOW"
    }

    // MARK: lede — hero figures

    private var lede: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                caplabel("Chunks indexed")
                heroFigure(stats.chunkCount)
                Text("Across \(stats.itemCount) sources, every chunk embedded locally and ready to cite — nothing left your Mac.")
                    .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                    .lineSpacing(2).frame(maxWidth: 280, alignment: .leading).padding(.top, DS.Space.x3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            columnRule
            smallFigure("Sources", "\(stats.itemCount)", unit: "\(stats.tagCount) tags")
            columnRule
            smallFigure("On disk", diskNumber, unit: "\(diskUnit) used")
        }
        .padding(.vertical, DS.Space.x5)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.ColorToken.borderDefault).frame(height: 1) }
    }

    private func heroFigure(_ n: Int) -> some View {
        let g = grouped(n)
        let parts = g.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let head = parts.count > 1 ? parts.dropLast().joined(separator: ",") + "," : ""
        let tail = parts.last ?? g
        return (Text(head).foregroundStyle(DS.ColorToken.textPrimary)
                + Text(tail).foregroundStyle(DS.ColorToken.iris))
            .font(.system(size: 70, weight: .bold, design: .serif)).tracking(-1)
            .lineLimit(1).minimumScaleFactor(0.5)
    }

    private func smallFigure(_ label: String, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            caplabel(label)
            Text(value).font(.system(size: 40, weight: .bold, design: .serif)).tracking(-0.5)
                .foregroundStyle(DS.ColorToken.textPrimary).lineLimit(1).minimumScaleFactor(0.5)
            Text(unit).font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary)
                .padding(.top, DS.Space.x2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, DS.Space.x4)
    }

    private var diskNumber: String {
        let mb = Double(stats.totalBytes) / 1_048_576
        return mb >= 100 ? String(Int(mb)) : String(format: "%.1f", mb)
    }
    private var diskUnit: String { "megabytes" }

    // MARK: body — two columns

    private var bodyColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            composition.frame(maxWidth: .infinity, alignment: .leading)
            columnRule
            VStack(alignment: .leading, spacing: DS.Space.x6) {
                activity
                if !stats.topCited.isEmpty { mostCited }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DS.Space.x4)
        }
        .padding(.vertical, DS.Space.x5)
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectTitle("Composition", "What the library is made of, by kind.")
            ForEach(Array(stats.byKind.enumerated()), id: \.element.kind) { idx, entry in
                HStack(spacing: DS.Space.x3) {
                    Text(entry.kind.rawValue).font(DS.Typo.body).frame(width: 92, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        let frac = Double(entry.count) / Double(max(stats.maxKindCount, 1))
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.ColorToken.surfaceOverlay).frame(height: 8)
                            Capsule().fill(idx == 0 ? DS.ColorToken.iris : DS.ColorToken.textPrimary)
                                .frame(width: max(4, g.size.width * frac), height: 8)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 22)
                    Text("\(entry.count)").font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textSecondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .overlay(alignment: .top) { Rectangle().fill(subtle).frame(height: 1) }
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            sectTitle("Activity", "Items ingested per day · last \(stats.activity.count) days.")
            let maxV = max(stats.activity.max() ?? 1, 1)
            let peak = stats.activity.firstIndex(of: stats.activity.max() ?? 0)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(stats.activity.enumerated()), id: \.offset) { i, v in
                    Rectangle()
                        .fill(i == peak && v > 0 ? DS.ColorToken.iris : DS.ColorToken.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: max(2, CGFloat(v) / CGFloat(maxV) * 120))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1, topTrailingRadius: 1))
                }
            }
            .frame(height: 132, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.ColorToken.borderDefault).frame(height: 1) }
        }
    }

    private var mostCited: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectTitle("Most cited", "The sources your answers lean on.")
            HStack {
                Text("SOURCE").font(DS.Typo.caption).tracking(0.8)
                Spacer()
                Text("CITES").font(DS.Typo.caption).tracking(0.8)
            }
            .foregroundStyle(DS.ColorToken.textTertiary)
            .padding(.vertical, DS.Space.x2)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.ColorToken.textPrimary).frame(height: 1) }
            ForEach(stats.topCited, id: \.item.id) { entry in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.item.path)])
                } label: {
                    HStack {
                        Text(entry.item.title).font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(DS.ColorToken.textSecondary).lineLimit(1)
                        Spacer(minLength: DS.Space.x2)
                        Text("\(entry.count)").font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textPrimary)
                    }
                    .padding(.vertical, DS.Space.x3)
                }
                .buttonStyle(.plain).help("Reveal \(entry.item.path)")
                .overlay(alignment: .bottom) { Rectangle().fill(subtle).frame(height: 1) }
            }
        }
    }

    /// Coverage as a gradient bar — fills vermilion→green; the fuller (more labelled)
    /// the library, the more of the green end shows.
    private var coverageBar: some View {
        let cov = TagStats.coverage(labelled: labelledCount, total: allItemsCache.count)
        let fraction = CGFloat(cov.pct) / 100
        return VStack(alignment: .leading, spacing: DS.Space.x1) {
            Text(cov.text).font(DS.Typo.caption)
                .foregroundStyle(cov.pct >= 80 ? DS.ColorToken.success : DS.ColorToken.iris)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.ColorToken.canvasRaised)
                    Capsule()
                        .fill(LinearGradient(colors: [DS.ColorToken.iris, DS.ColorToken.success],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .padding(.top, DS.Space.x2)
    }

    // MARK: health banner

    /// A compact health line with one-tap fixes — shown only when there's something
    /// worth acting on (low coverage with untagged files, or near-duplicate labels).
    @ViewBuilder private var healthBanner: (some View)? {
        let total = allItemsCache.count
        let cov = TagStats.coverage(labelled: labelledCount, total: total)
        let untagged = max(0, total - labelledCount)
        let dups = nearDupClusters.count
        let needsLabels = untagged >= 3 && cov.pct < 70
        if total > 0 && (needsLabels || dups > 0) {
            HStack(spacing: DS.Space.x3) {
                Image(systemName: "stethoscope").font(.system(size: 12)).foregroundStyle(DS.ColorToken.iris)
                Text("Health — \(cov.pct)% labelled · \(untagged) untagged"
                     + (dups > 0 ? " · \(dups) duplicate label group\(dups == 1 ? "" : "s")" : ""))
                    .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                Spacer(minLength: DS.Space.x3)
                if needsLabels { fixButton("Auto-label",
                    "Auto-label my untagged files using auto_label_untagged — preview first, then ask me before applying.") }
                if dups > 0 { fixButton("Merge dups",
                    "Find near-duplicate labels and merge each group using merge_tags — preview first, then ask before applying.") }
                Button { withAnimation(DS.Motion.snappy) { dismissedHealth = true } } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(DS.ColorToken.textTertiary)
                }.buttonStyle(.plain).help("Dismiss")
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.ColorToken.iris.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(DS.ColorToken.iris.opacity(0.25)))
            .padding(.top, DS.Space.x4)
        }
    }

    private func fixButton(_ label: String, _ prompt: String) -> some View {
        Button { onAskText(prompt) } label: {
            Text(label).font(DS.Typo.caption).foregroundStyle(.white)
                .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                .background(DS.ColorToken.iris, in: Capsule())
        }.buttonStyle(.plain).help(prompt)
    }

    // MARK: themes

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectTitle("Themes", "Topics that recur across your files — tap one to explore it.")
            FlowLayout(spacing: DS.Space.x2) {
                ForEach(themes, id: \.term) { t in
                    Button {
                        onAskText("Summarize what my library says about \u{201C}\(t.term)\u{201D}, with sources.")
                    } label: {
                        HStack(spacing: DS.Space.x1) {
                            Text(t.term).font(DS.Typo.callout)
                            Text("\(t.count)").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                        }
                        .foregroundStyle(DS.ColorToken.textSecondary)
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                        .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Tap to summarize · right-click for more")
                    .contextMenu {
                        Button("Summarize this topic") {
                            onAskText("Summarize what my library says about \u{201C}\(t.term)\u{201D}, with sources.")
                        }
                        Button("Tag matching files \u{201C}\(t.term)\u{201D}") {
                            onAskText("Tag every file about \u{201C}\(t.term)\u{201D} with the label '\(t.term)' using tag_search_results — preview first, then ask me before applying.")
                        }
                        Button("Find files about this") {
                            onAskText("Find my files about \u{201C}\(t.term)\u{201D}.")
                        }
                    }
                }
            }
            .padding(.top, DS.Space.x3)
        }
        .padding(.top, DS.Space.x8)
    }

    // MARK: tag graph

    private var tagGraphSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectTitle("Label constellation", "How your labels cluster — lines link labels that share files.")
            coverageBar
            TagGraphView(graph: tagGraph, onTapTag: onSelectTag)
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Space.x4)
        }
        .padding(.top, DS.Space.x8)
    }

    // MARK: recent changes

    private var recentChanges: some View {
        let shown = recent
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                sectTitle("Changed recently", "Files added or modified in the last \(windowDays) days.")
                Spacer()
                windowPicker
            }
            if shown.isEmpty {
                Text("Nothing changed in this window.").font(DS.Typo.body)
                    .foregroundStyle(DS.ColorToken.textTertiary).padding(.vertical, DS.Space.x4)
            }
            ForEach(shown.prefix(10)) { item in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    HStack(spacing: DS.Space.x3) {
                        Image(systemName: item.kind.sfSymbol).font(.system(size: 11))
                            .foregroundStyle(DS.ColorToken.iris).frame(width: 16)
                        Text(item.title).font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(DS.ColorToken.textSecondary).lineLimit(1)
                        Spacer(minLength: DS.Space.x2)
                        Text(Format.ago(max(item.modifiedAt, item.createdAt)))
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    }
                    .padding(.vertical, DS.Space.x3)
                }
                .buttonStyle(.plain).help("Reveal \(item.path)")
                .overlay(alignment: .bottom) { Rectangle().fill(subtle).frame(height: 1) }
            }
            if shown.count > 10 {
                Text("+ \(shown.count - 10) more").font(DS.Typo.caption)
                    .foregroundStyle(DS.ColorToken.textTertiary).padding(.top, DS.Space.x2)
            }
        }
        .padding(.top, DS.Space.x8)
    }

    /// 7 / 30 / 90-day window selector for the recent-changes panel.
    private var windowPicker: some View {
        HStack(spacing: 0) {
            ForEach([7, 30, 90], id: \.self) { days in
                let active = windowDays == days
                Button { withAnimation(DS.Motion.snappy) { windowDays = days } } label: {
                    Text("\(days)d").font(DS.Typo.caption)
                        .foregroundStyle(active ? Color.white : DS.ColorToken.textSecondary)
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                        .background { if active { DS.ColorToken.iris } }
                }.buttonStyle(.plain)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
    }

    // MARK: pull-quote

    private var pullQuote: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            (Text("Every answer is traced to a source — your knowledge, grounded in ")
                .foregroundStyle(DS.ColorToken.textPrimary)
             + Text(topNeighborhood).foregroundStyle(DS.ColorToken.iris)
             + Text(". The rest of the city stays dark, waiting to be asked.")
                .foregroundStyle(DS.ColorToken.textPrimary))
                .font(.system(size: 23, weight: .semibold, design: .serif)).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Text("OBSERVED BY MNEMOSYNE · DEEPSEEK-CHAT")
                .font(DS.Typo.caption).tracking(1).foregroundStyle(DS.ColorToken.textTertiary)
        }
        .padding(.top, DS.Space.x6)
        .overlay(alignment: .top) { Rectangle().fill(DS.ColorToken.borderDefault).frame(height: 1) }
    }

    private var topNeighborhood: String { stats.byKind.first.map { "\($0.kind.rawValue) files" } ?? "your library" }

    // MARK: shared

    private func caplabel(_ s: String) -> some View {
        Text(s.uppercased()).font(DS.Typo.caption).tracking(1)
            .foregroundStyle(DS.ColorToken.textTertiary).padding(.bottom, DS.Space.x3)
    }

    private func sectTitle(_ title: String, _ deck: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 19, weight: .bold, design: .serif))
                .foregroundStyle(DS.ColorToken.textPrimary)
            Text(deck).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
        }
        .padding(.bottom, DS.Space.x4)
    }

    private var columnRule: some View {
        Rectangle().fill(subtle).frame(width: 1).frame(maxHeight: .infinity)
    }

    private func grouped(_ n: Int) -> String {
        let s = String(n); var out = ""; var c = 0
        for ch in s.reversed() { if c != 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }
}

#Preview("Knowledge Ledger") {
    InsightsView(store: try! KnowledgeStore(
        directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LedgerPreview-\(UUID().uuidString)")))
        .frame(width: 880, height: 820).background(DS.ColorToken.canvas)
}
