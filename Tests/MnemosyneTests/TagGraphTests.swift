import XCTest
@testable import Mnemosyne

final class TagGraphTests: XCTestCase {

    func testBuildsNodesAndEdgesAmongTopLabels() {
        let counts = [("alpha", 5), ("beta", 3), ("gamma", 2)]
        let pairs = [("alpha", "beta", 4), ("alpha", "gamma", 1)]
        let g = TagGraph.build(counts: counts, pairs: pairs)
        XCTAssertEqual(g.nodes.map(\.tag), ["alpha", "beta", "gamma"])
        XCTAssertEqual(g.nodes.map(\.weight), [5, 3, 2])
        // Edges reference node indices, ordered a<b.
        XCTAssertTrue(g.edges.contains(.init(a: 0, b: 1, weight: 4)))
        XCTAssertTrue(g.edges.contains(.init(a: 0, b: 2, weight: 1)))
    }

    func testTopNLimitsNodesAndDropsOutsideEdges() {
        let counts = [("a", 9), ("b", 8), ("c", 7), ("d", 1)]
        // 'd' is outside top-3, so the a–d edge must be dropped.
        let pairs = [("a", "b", 5), ("a", "d", 3)]
        let g = TagGraph.build(counts: counts, pairs: pairs, topNodes: 3)
        XCTAssertEqual(g.nodes.count, 3)
        XCTAssertFalse(g.nodes.contains { $0.tag == "d" })
        XCTAssertEqual(g.edges.count, 1, "a–d edge dropped since 'd' isn't a node")
        XCTAssertEqual(g.edges.first, .init(a: 0, b: 1, weight: 5))
    }

    func testAnglesDistributedAroundCircle() {
        let g = TagGraph.build(counts: [("a", 1), ("b", 1), ("c", 1), ("d", 1)], pairs: [])
        XCTAssertEqual(g.nodes[0].angle, 0, accuracy: 1e-9)
        XCTAssertEqual(g.nodes[1].angle, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(g.nodes[2].angle, .pi, accuracy: 1e-9)
    }

    func testEmpty() {
        let g = TagGraph.build(counts: [], pairs: [])
        XCTAssertTrue(g.nodes.isEmpty && g.edges.isEmpty)
    }

    func testNodePointPlacesFirstNodeAtTop() {
        let size = CGSize(width: 200, height: 200)
        // angle 0 → top of the ring (center.x, center.y - radius).
        let p = TagGraph.nodePoint(angle: 0, size: size, inset: 40)
        XCTAssertEqual(p.x, 100, accuracy: 0.001)
        XCTAssertEqual(p.y, 40, accuracy: 0.001, "radius 60 above center (100 − 60)")
    }

    func testNearestNodeHitTest() {
        let nodes = TagGraph.build(counts: [("a", 1), ("b", 1), ("c", 1), ("d", 1)], pairs: []).nodes
        let size = CGSize(width: 200, height: 200)
        // A tap right on node 'a' (top) selects it.
        let pa = TagGraph.nodePoint(angle: nodes[0].angle, size: size)
        XCTAssertEqual(TagGraph.nearestNode(nodes, to: pa, size: size), "a")
        // A tap in the dead center hits nothing (outside any node's radius).
        XCTAssertNil(TagGraph.nearestNode(nodes, to: CGPoint(x: 100, y: 100), size: size, radius: 20))
    }
}
