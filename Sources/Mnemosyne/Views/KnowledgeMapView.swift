import SwiftUI

/// A spatial map of the library (per the design system's "Knowledge Map"): items
/// scatter into topic neighborhoods on a graph-paper field, wrapped in dashed soft
/// hulls. Each node links to its cluster's most-cited "local hub", with a few
/// inter-cluster bridges. Node size = times cited; the most-cited overall glows
/// vermilion. Hover shows a tooltip; tap opens the item. DS tokens only.
struct KnowledgeMapView: View {
    let items: [KnowledgeItem]
    let tagsByItem: [String: [String]]
    let citationCounts: [String: Int]
    var onOpen: (KnowledgeItem) -> Void

    @State private var hovered: String?

    private func cites(_ it: KnowledgeItem) -> Int { citationCounts[it.id] ?? 0 }
    private func radius(_ it: KnowledgeItem) -> CGFloat { 5 + min(CGFloat(cites(it)), 14) * 1.6 }
    private var topCitedID: String? {
        guard let top = items.max(by: { cites($0) < cites($1) }), cites(top) > 0 else { return nil }
        return top.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            header
            GeometryReader { geo in stage(in: geo.size) }
                .frame(minHeight: 500)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Knowledge Map").font(DS.Typo.title1).foregroundStyle(DS.ColorToken.textPrimary)
                Text("\(items.count) items · \(clusters.count) clusters · proximity = relatedness · size = times cited")
                    .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
            }
            Spacer()
            HStack(spacing: DS.Space.x4) {
                legendSwatch("Source", DS.ColorToken.textPrimary)
                legendSwatch("Most cited", DS.ColorToken.iris)
            }
        }
    }

    private func legendSwatch(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label.uppercased()).font(DS.Typo.caption).tracking(0.8)
                .foregroundStyle(DS.ColorToken.textTertiary)
        }
    }

    // MARK: stage

    private func stage(in size: CGSize) -> some View {
        let hubs = layout(in: size)
        return ZStack {
            Canvas { ctx, sz in
                drawGrid(&ctx, sz)
                drawHullsAndLinks(hubs, into: &ctx)
            }
            ForEach(hubs) { hub in
                clusterLabel(hub)
                ForEach(hub.placed) { p in dot(p) }
            }
        }
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }

    private func dot(_ p: Placed) -> some View {
        let isTop = p.item.id == topCitedID
        let isHover = p.item.id == hovered
        let stroke = isTop ? DS.ColorToken.iris : DS.ColorToken.textPrimary
        return ZStack {
            Circle()
                .fill(isHover ? stroke : DS.ColorToken.surface)
                .overlay(Circle().strokeBorder(stroke, lineWidth: 1.5))
                .frame(width: p.r * 2, height: p.r * 2)
            Circle().fill(isHover ? DS.ColorToken.surface : stroke)
                .frame(width: max(3, p.r * 0.64), height: max(3, p.r * 0.64))
        }
        .overlay(alignment: .bottom) { if isHover { tooltip(p).offset(y: -(p.r + 14)) } }
        .position(p.point)
        .onHover { hovered = $0 ? p.item.id : (hovered == p.item.id ? nil : hovered) }
        .onTapGesture { onOpen(p.item) }
    }

    private func clusterLabel(_ hub: Hub) -> some View {
        Text(hub.cluster.label.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1)
            .foregroundStyle(DS.ColorToken.textTertiary)
            .position(x: hub.hull.minX + 32, y: hub.hull.minY - 4)
    }

    private func tooltip(_ p: Placed) -> some View {
        HStack(spacing: DS.Space.x2) {
            Text(p.item.title).font(.system(size: 11, design: .monospaced))
            Text("cited \(cites(p.item))×").font(.system(size: 11))
                .foregroundStyle(DS.ColorToken.canvas.opacity(0.6))
        }
        .foregroundStyle(DS.ColorToken.canvas)
        .padding(.horizontal, DS.Space.x2).padding(.vertical, 6)
        .background(DS.ColorToken.textPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }

    // MARK: drawing

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 40
        let line = DS.ColorToken.textPrimary.opacity(0.05)
        var x: CGFloat = 0
        while x < size.width { var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); ctx.stroke(p, with: .color(line), lineWidth: 1); x += step }
        var y: CGFloat = 0
        while y < size.height { var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); ctx.stroke(p, with: .color(line), lineWidth: 1); y += step }
    }

    private func drawHullsAndLinks(_ hubs: [Hub], into ctx: inout GraphicsContext) {
        let linkColor = DS.ColorToken.borderDefault
        for hub in hubs {
            // soft dashed hull
            let hull = Path(roundedRect: hub.hull, cornerRadius: 34, style: .continuous)
            ctx.fill(hull, with: .color(DS.ColorToken.textPrimary.opacity(0.025)))
            ctx.stroke(hull, with: .color(linkColor), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            // links: each node → cluster's most-cited local hub
            if let localHub = hub.placed.max(by: { cites($0.item) < cites($1.item) }) {
                for p in hub.placed where p.item.id != localHub.item.id {
                    var link = Path(); link.move(to: localHub.point); link.addLine(to: p.point)
                    ctx.stroke(link, with: .color(linkColor), lineWidth: 1)
                }
            }
        }
        // a few inter-cluster bridges: connect consecutive clusters' local hubs
        let localHubs = hubs.compactMap { $0.placed.max(by: { cites($0.item) < cites($1.item) }) }
        if localHubs.count > 1 {
            for i in 0..<(localHubs.count - 1) {
                var b = Path(); b.move(to: localHubs[i].point); b.addLine(to: localHubs[i + 1].point)
                ctx.stroke(b, with: .color(linkColor), lineWidth: 1)
            }
        }
    }

    // MARK: clustering + layout

    struct Placed: Identifiable { let item: KnowledgeItem; let point: CGPoint; let r: CGFloat; var id: String { item.id } }
    struct Hub: Identifiable { let cluster: Cluster; let center: CGPoint; let placed: [Placed]; let hull: CGRect; var id: String { cluster.id } }
    struct Cluster: Identifiable { let id: String; let label: String; let items: [KnowledgeItem] }

    private var clusters: [Cluster] {
        var groups: [String: [KnowledgeItem]] = [:]
        for it in items {
            let key = tagsByItem[it.id]?.first ?? it.kind.rawValue
            groups[key, default: []].append(it)
        }
        var result = groups.map { Cluster(id: $0.key, label: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
        if result.count > 6 {
            let tail = result.dropFirst(5).flatMap(\.items)
            result = Array(result.prefix(5)) + [Cluster(id: "·other", label: "Other", items: tail)]
        }
        return result
    }

    /// FNV-style hash → 0…1 (matches the design's deterministic scatter).
    private func hash(_ s: String) -> Double {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return Double(h) / Double(UInt32.max)
    }

    private func layout(in size: CGSize) -> [Hub] {
        let cs = clusters
        guard !cs.isEmpty else { return [] }
        let canvasCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        let ringR = min(size.width, size.height) / 2 * (cs.count == 1 ? 0 : 0.5)
        var hubs: [Hub] = []
        for (ci, cluster) in cs.enumerated() {
            let a = -Double.pi / 2 + Double(ci) / Double(cs.count) * 2 * .pi
            let center = CGPoint(x: canvasCenter.x + ringR * cos(a), y: canvasCenter.y + ringR * sin(a))
            var placed: [Placed] = []
            for it in cluster.items.prefix(12) {
                let ang = hash(it.title) * 2 * .pi
                let rr = 26 + hash(it.title + "r") * 62
                let p = CGPoint(x: center.x + cos(ang) * rr, y: center.y + sin(ang) * rr * 0.82)
                placed.append(Placed(item: it, point: p, r: radius(it)))
            }
            let xs = placed.map(\.point.x) + [center.x], ys = placed.map(\.point.y) + [center.y]
            let minX = (xs.min() ?? center.x) - 30, maxX = (xs.max() ?? center.x) + 30
            let minY = (ys.min() ?? center.y) - 30, maxY = (ys.max() ?? center.y) + 30
            hubs.append(Hub(cluster: cluster, center: center, placed: placed,
                            hull: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)))
        }
        return hubs
    }
}

#Preview("Knowledge map") {
    func item(_ id: String, _ title: String, _ kind: ItemKind) -> KnowledgeItem {
        KnowledgeItem(id: id, path: "/tmp/\(title)", title: title, kind: kind,
                      contentHash: id, byteSize: 0, createdAt: Date(), modifiedAt: Date())
    }
    let items = [
        item("1", "vector-db-notes.md", .markdown), item("2", "faiss-paper.pdf", .pdf),
        item("3", "hnsw-graphs.pdf", .pdf), item("4", "embed_pipeline.py", .code),
        item("5", "architecture.png", .image), item("6", "standup-06-12.m4a", .audioTranscript),
        item("7", "ROADMAP.md", .markdown), item("8", "Jane Smith.vcf", .contact),
    ]
    let tags = ["1": ["search"], "2": ["search"], "3": ["search"], "4": ["models"],
                "5": ["arch"], "6": ["meetings"], "7": ["meetings"], "8": ["people"]]
    let cites = ["1": 9, "2": 7, "3": 4, "4": 5, "5": 4, "6": 4, "7": 3, "8": 2]
    return KnowledgeMapView(items: items, tagsByItem: tags, citationCounts: cites, onOpen: { _ in })
        .padding(DS.Space.x6).frame(width: 900, height: 620).background(DS.ColorToken.canvas)
}
