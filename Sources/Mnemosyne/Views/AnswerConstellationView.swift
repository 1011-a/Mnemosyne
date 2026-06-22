import SwiftUI

/// An alternate, spatial rendering of an assistant answer (per the Mnemosyne
/// design system's "Answer Constellation"): the claim is a dark core on the left,
/// each cited source is a node in a column on the right, joined by thin ink cubic
/// Bézier threads. Hovering a source highlights its thread, dims the others, and
/// reveals the grounding snippet in a readout. The primary source is vermilion.
struct AnswerConstellationView: View {
    let claim: String
    let citations: [Citation]
    var onReveal: (Citation) -> Void

    @State private var active: UUID?

    private var primaryID: UUID? { citations.min(by: { $0.index < $1.index })?.id }
    private var revealed: Citation? { citations.first { $0.id == active } }

    private let stageHeight: CGFloat = 392

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            kicker
            Text(claim)
                .font(.system(size: 21, weight: .semibold, design: .serif))
                .foregroundStyle(DS.ColorToken.textPrimary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in stage(in: geo.size) }
                .frame(height: stageHeight)
            readout
        }
    }

    private var kicker: some View {
        HStack(spacing: DS.Space.x2) {
            Rectangle().fill(DS.ColorToken.borderDefault).frame(width: 18, height: 1)
            Text("Grounded in \(citations.count) source\(citations.count == 1 ? "" : "s")")
                .font(DS.Typo.caption).tracking(0.6)
                .foregroundStyle(DS.ColorToken.textTertiary)
        }
    }

    // MARK: stage

    private func stage(in size: CGSize) -> some View {
        let core = CGPoint(x: size.width * 0.17, y: size.height * 0.5)
        let pts = nodePoints(in: size)
        return ZStack {
            threads(core: core, points: pts)
            coreNode.position(core)
            ForEach(citations) { c in
                if let p = pts[c.id] { nodeAndLabels(c, at: p) }
            }
        }
    }

    private var coreNode: some View {
        ZStack {
            Circle().fill(DS.ColorToken.textPrimary).frame(width: 68, height: 68)
            VStack(spacing: 0) {
                Text("THE").font(.system(size: 10, weight: .semibold)).tracking(0.5)
                Text("CLAIM").font(.system(size: 10, weight: .semibold)).tracking(0.5)
            }
            .foregroundStyle(DS.ColorToken.canvas)
        }
    }

    @ViewBuilder private func nodeAndLabels(_ c: Citation, at p: CGPoint) -> some View {
        let isPrimary = c.id == primaryID
        let isActive = c.id == active
        let dim = active != nil && !isActive
        let kind = TypeDetector.kind(for: URL(fileURLWithPath: c.path)) ?? .unknown
        let ringFill = isActive ? (isPrimary ? DS.ColorToken.iris : DS.ColorToken.textPrimary) : DS.ColorToken.surface
        let glyph = isActive ? DS.ColorToken.canvas : (isPrimary ? DS.ColorToken.iris : DS.ColorToken.textPrimary)
        Group {
            ZStack {
                Circle().fill(ringFill)
                    .overlay(Circle().strokeBorder(isPrimary ? DS.ColorToken.iris : DS.ColorToken.borderStrong,
                                                   lineWidth: 1.25))
                    .frame(width: 52, height: 52)
                Image(systemName: kind.sfSymbol).font(.system(size: 15)).foregroundStyle(glyph)
            }
            .position(p)
            .onHover { active = $0 ? c.id : (active == c.id ? nil : active) }
            .onTapGesture { onReveal(c) }

            Text("[\(c.index)]").font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary)
                .position(x: p.x, y: p.y + 40)
            Text(c.title).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.ColorToken.textSecondary).lineLimit(1)
                .frame(maxWidth: 150).position(x: p.x, y: p.y + 54)
        }
        .opacity(dim ? 0.28 : 1)
        .animation(DS.Motion.base, value: active)
    }

    private func threads(core: CGPoint, points: [UUID: CGPoint]) -> some View {
        Canvas { ctx, _ in
            for c in citations {
                guard let p = points[c.id] else { continue }
                var path = Path()
                path.move(to: CGPoint(x: core.x + 34, y: core.y))
                path.addCurve(to: CGPoint(x: p.x - 26, y: p.y),
                              control1: CGPoint(x: core.x + 180, y: core.y),
                              control2: CGPoint(x: p.x - 180, y: p.y))
                let isActive = c.id == active
                let isPrimary = c.id == primaryID
                let dim = active != nil && !isActive
                let color: Color = isActive ? DS.ColorToken.textPrimary
                    : (isPrimary ? DS.ColorToken.iris.opacity(0.4)
                       : DS.ColorToken.textPrimary.opacity(dim ? 0.04 : 0.22))
                ctx.stroke(path, with: .color(color), lineWidth: isActive ? 1.75 : 1.25)
            }
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.x3) {
            if let c = revealed {
                Text("[\(c.index)]").font(DS.Typo.mono).foregroundStyle(DS.ColorToken.iris)
                (Text(c.title).font(.system(size: 13, design: .monospaced)).foregroundStyle(DS.ColorToken.textPrimary)
                 + Text("  —  \(c.snippetPreview)").font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hover a source to trace its thread into the claim.")
                    .font(DS.Typo.callout.italic()).foregroundStyle(DS.ColorToken.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, DS.Space.x3)
        .frame(minHeight: 44, alignment: .top)
        .overlay(alignment: .top) { Rectangle().fill(DS.ColorToken.borderDefault).frame(height: 1) }
    }

    /// Sources stack in a column on the right, evenly spread top→bottom.
    private func nodePoints(in size: CGSize) -> [UUID: CGPoint] {
        let x = size.width * 0.74
        let n = citations.count
        var out: [UUID: CGPoint] = [:]
        for (i, c) in citations.enumerated() {
            let frac = n <= 1 ? 0.5 : 0.14 + (0.72 * Double(i) / Double(n - 1))
            out[c.id] = CGPoint(x: x, y: size.height * frac)
        }
        return out
    }
}

#Preview("Answer constellation") {
    let cites = [
        Citation(index: 1, title: "vector-db-notes.md", path: "/tmp/vector-db-notes.md",
                 snippet: "FAISS vs SQLite-vss recall tradeoffs on device — leans SQLite-vss for local retrieval."),
        Citation(index: 2, title: "faiss-paper.pdf", path: "/tmp/faiss-paper.pdf",
                 snippet: "Efficient similarity search of dense vectors; IVF and HNSW indexes for large corpora."),
        Citation(index: 3, title: "standup-2026-06-12.m4a", path: "/tmp/standup.m4a",
                 snippet: "Transcript — benchmark recall@10 on the on-device index before shipping."),
    ]
    return AnswerConstellationView(
        claim: "You compared FAISS and SQLite-vss in a note and two papers — the note leans on-device, the papers cover indexing at scale.",
        citations: cites, onReveal: { _ in })
        .padding(DS.Space.x6).frame(width: 900).background(DS.ColorToken.canvas)
}
