import SwiftUI

/// Renders a `TagGraph.Graph` as a circular constellation: nodes (labels) placed on
/// a ring by their `angle`, sized by use-count, with edges for co-occurring pairs.
/// Pure layout (the math lives in TagGraph); this just paints it on a Canvas.
struct TagGraphView: View {
    let graph: TagGraph.Graph
    /// Tapping a node calls this with its label (for cross-view filtering).
    var onTapTag: (String) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            canvas(size: geo.size)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    if let tag = TagGraph.nearestNode(graph.nodes, to: value.location, size: geo.size) {
                        onTapTag(tag)
                    }
                })
        }
        .accessibilityLabel("Label co-occurrence graph with \(graph.nodes.count) labels")
    }

    private func canvas(size: CGSize) -> some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxWeight = max(1, graph.nodes.map(\.weight).max() ?? 1)
            func point(_ i: Int) -> CGPoint { TagGraph.nodePoint(angle: graph.nodes[i].angle, size: size) }

            // Edges first (under the nodes). Width + opacity scale with shared-file count.
            let maxEdge = max(1, graph.edges.map(\.weight).max() ?? 1)
            for e in graph.edges where e.a < graph.nodes.count && e.b < graph.nodes.count {
                var path = Path()
                path.move(to: point(e.a)); path.addLine(to: point(e.b))
                let t = Double(e.weight) / Double(maxEdge)
                ctx.stroke(path, with: .color(DS.ColorToken.iris.opacity(0.12 + 0.33 * t)),
                           lineWidth: 0.5 + 2.5 * t)
            }

            // Nodes + labels.
            for (i, node) in graph.nodes.enumerated() {
                let p = point(i)
                let r = 4 + 10 * CGFloat(node.weight) / CGFloat(maxWeight)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(DS.ColorToken.iris))
                let label = Text("\(node.tag) \(node.weight)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.ColorToken.textSecondary)
                let outward = CGPoint(x: p.x + (p.x - center.x) * 0.16,
                                      y: p.y + (p.y - center.y) * 0.16)
                ctx.draw(label, at: outward, anchor: labelAnchor(for: p, center: center))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Anchor the label so it sits outside the ring (left/right of the node).
    private func labelAnchor(for p: CGPoint, center: CGPoint) -> UnitPoint {
        p.x >= center.x ? .leading : .trailing
    }
}
