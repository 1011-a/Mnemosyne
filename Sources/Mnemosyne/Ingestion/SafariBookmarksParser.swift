import Foundation

/// One imported bookmark: a title and its URL.
struct Bookmark: Equatable, Sendable {
    let title: String
    let url: String
}

/// Parses a Safari `Bookmarks.plist` (the nested WebBookmarkType tree) into a
/// flat list of bookmarks. Pure and dependency-free; `parse` works on raw plist
/// `Data` so it's unit-testable. Skips the Reading List and history.
enum SafariBookmarksParser {
    static func parse(_ data: Data) -> [Bookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = root as? [String: Any] else { return [] }
        var out: [Bookmark] = []
        var seen = Set<String>()
        walk(dict, into: &out, seen: &seen)
        return out
    }

    private static func walk(_ node: [String: Any], into out: inout [Bookmark], seen: inout Set<String>) {
        let type = node["WebBookmarkType"] as? String
        // A leaf bookmark: { WebBookmarkType: Leaf, URLString, URIDictionary: { title } }
        if type == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String {
            let trimmed = url.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
            out.append(Bookmark(title: (title?.isEmpty == false ? title! : trimmed), url: trimmed))
            return
        }
        // Skip the Reading List folder (its leaves are saved-for-later, not bookmarks).
        if (node["Title"] as? String) == "com.apple.ReadingList" { return }
        // A list/folder: recurse into Children.
        if let children = node["Children"] as? [[String: Any]] {
            for child in children { walk(child, into: &out, seen: &seen) }
        }
    }
}
