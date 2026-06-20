import Foundation

/// A named, persisted Library filter (query + kinds + tag) — a "smart folder".
struct SavedSearch: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var query: String
    var kinds: [ItemKind]
    var tag: String?
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, query: String,
         kinds: [ItemKind], tag: String?, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.query = query
        self.kinds = kinds; self.tag = tag; self.createdAt = createdAt
    }

    /// A readable auto-name from the filter contents.
    static func defaultName(query: String, kinds: [ItemKind], tag: String?) -> String {
        var parts: [String] = []
        if let tag, !tag.isEmpty { parts.append("#\(tag)") }
        parts.append(contentsOf: kinds.map(\.rawValue).sorted())
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("\"\(q)\"") }
        return parts.isEmpty ? "All items" : parts.joined(separator: " · ")
    }

    /// kinds serialized for SQLite (comma-separated raw values).
    var kindsField: String { kinds.map(\.rawValue).joined(separator: ",") }

    static func parseKinds(_ field: String) -> [ItemKind] {
        field.split(separator: ",").compactMap { ItemKind(rawValue: String($0)) }
    }
}
