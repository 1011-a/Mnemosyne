import Foundation

/// A persisted conversation. Messages are stored separately and loaded on demand.
struct ChatThread: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    init(id: String = UUID().uuidString, title: String = "New chat",
         createdAt: Date = Date(), updatedAt: Date = Date(), pinned: Bool = false) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.pinned = pinned
    }
}
