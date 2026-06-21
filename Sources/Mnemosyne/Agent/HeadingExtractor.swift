import Foundation

/// Pulls the HEADING hierarchy (the table of contents) out of a markdown/text document
/// for the `document_outline` tool — navigate a long file, jump to a section. Recognizes
/// ATX headings (`#` … `######`); the number of leading `#`s is the level. Pure +
/// deterministic → unit-testable. Distinct from `outline_item` (which asks the model for a
/// summary); this is the file's own exact structure.
enum HeadingExtractor {
    static func extract(_ text: String, max: Int = 150) -> [(level: Int, title: String)] {
        guard !text.isEmpty else { return [] }
        var out: [(Int, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            guard level >= 1, level <= 6 else { continue }
            // Require a space after the hashes (so "#tag" isn't a heading).
            let after = line.dropFirst(level)
            guard after.first == " " else { continue }
            let title = after.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
            if !title.isEmpty {
                out.append((level, title))
                if out.count >= max { break }
            }
        }
        return out
    }

    /// An indented outline (two spaces per level, normalized so the shallowest heading sits
    /// at the left), or nil when the document has no headings.
    static func outline(_ text: String, max: Int = 150) -> String? {
        let heads = extract(text, max: max)
        guard !heads.isEmpty else { return nil }
        let base = heads.map(\.level).min() ?? 1
        return heads.map { h in
            String(repeating: "  ", count: h.level - base) + "• " + h.title
        }.joined(separator: "\n")
    }
}
