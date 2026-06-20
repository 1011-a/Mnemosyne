import Foundation

/// Derives 2–3 natural follow-up questions to show as chips after an answer —
/// deepening the AI-first loop without an extra LLM round-trip. Source-grounded
/// follow-ups first (from the cited files), then useful generics.
enum FollowupSuggester {
    static func suggest(question: String, citations: [Citation], max: Int = 3) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let key = s.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key); out.append(s)
        }

        // Source-grounded: dig into the top distinct cited files.
        var usedTitles = Set<String>()
        for c in citations {
            let name = displayTitle(c.title)
            guard !name.isEmpty, !usedTitles.contains(name.lowercased()) else { continue }
            usedTitles.insert(name.lowercased())
            add("Tell me more about \(name)")
            if usedTitles.count == 2 { break }
        }

        // Useful generics to round out the set.
        add("What are the key takeaways?")
        add("How does this relate to my other files?")

        return Array(out.prefix(max))
    }

    /// A human title: drop the extension, turn separators into spaces.
    static func displayTitle(_ raw: String) -> String {
        var name = raw
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            // only strip a short, file-like extension
            let ext = name[name.index(after: dot)...]
            if ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                name = String(name[..<dot])
            }
        }
        return name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
