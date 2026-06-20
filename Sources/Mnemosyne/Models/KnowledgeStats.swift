import Foundation

/// Aggregate snapshot of the knowledge base for the Insights dashboard.
struct KnowledgeStats: Sendable {
    let itemCount: Int
    let chunkCount: Int
    let threadCount: Int
    let tagCount: Int
    let totalBytes: Int64
    let byKind: [(kind: ItemKind, count: Int)]
    let oldest: Date?
    let newest: Date?
    /// Items modified per day over a recent window (oldest → newest).
    let activity: [Int]
    /// Most-referenced items in answers, highest first.
    let topCited: [(item: KnowledgeItem, count: Int)]

    static let empty = KnowledgeStats(itemCount: 0, chunkCount: 0, threadCount: 0, tagCount: 0,
                                      totalBytes: 0, byKind: [], oldest: nil, newest: nil,
                                      activity: [], topCited: [])

    /// Largest single-kind count, for scaling bars.
    var maxKindCount: Int { byKind.map(\.count).max() ?? 1 }
}
