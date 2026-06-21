import Foundation
import CoreGraphics

/// Builds a tiny, deterministic tag co-occurrence graph for the Insights mini-viz:
/// the top-N labels placed on a circle (nodes weighted by use-count) with edges for
/// pairs that co-occur. Pure (no view types) → unit-testable; the view just maps
/// each node's `angle` onto a circle and scales by `weight`.
enum TagGraph {
    struct Node: Equatable { let tag: String; let weight: Int; let angle: Double }
    struct Edge: Equatable { let a: Int; let b: Int; let weight: Int }
    struct Graph: Equatable { let nodes: [Node]; let edges: [Edge] }

    /// `counts` = labels with use-counts (most-used first); `pairs` = co-occurrences.
    /// Keeps only the top `topNodes` labels and the edges among them.
    static func build(counts: [(String, Int)], pairs: [(String, String, Int)], topNodes: Int = 12) -> Graph {
        let top = Array(counts.prefix(topNodes))
        let n = top.count
        var idx: [String: Int] = [:]
        for (i, c) in top.enumerated() { idx[c.0.lowercased()] = i }
        let nodes = top.enumerated().map { (i, c) in
            Node(tag: c.0, weight: c.1, angle: n > 0 ? 2 * Double.pi * Double(i) / Double(n) : 0)
        }
        var edges: [Edge] = []
        for p in pairs {
            guard let a = idx[p.0.lowercased()], let b = idx[p.1.lowercased()], a != b else { continue }
            edges.append(Edge(a: Swift.min(a, b), b: Swift.max(a, b), weight: p.2))
        }
        return Graph(nodes: nodes, edges: edges)
    }

    /// Screen position of a node at `angle` on the ring (top = angle 0). Shared by
    /// the Canvas painter and the tap hit-tester so they always agree.
    static func nodePoint(angle: Double, size: CGSize, inset: CGFloat = 44) -> CGPoint {
        let r = Swift.min(size.width, size.height) / 2 - inset
        let a = angle - .pi / 2
        return CGPoint(x: size.width / 2 + r * cos(a), y: size.height / 2 + r * sin(a))
    }

    /// The tag of the node nearest `point` within `radius`, or nil. Used for taps.
    static func nearestNode(_ nodes: [Node], to point: CGPoint, size: CGSize,
                            radius: CGFloat = 30, inset: CGFloat = 44) -> String? {
        var best: (tag: String, dist: CGFloat)?
        for n in nodes {
            let q = nodePoint(angle: n.angle, size: size, inset: inset)
            let d = hypot(q.x - point.x, q.y - point.y)
            if d <= radius, best == nil || d < best!.dist { best = (n.tag, d) }
        }
        return best?.tag
    }
}
