import Foundation
import Fathom

/// Builds a clickable markdown table of contents for the `generate_toc` tool — an indented
/// list of `- [Heading](#anchor)` links from a document's headings. Combines `HeadingExtractor`
/// (the heading hierarchy) and `Slugifier` (GitHub-style anchors). Pure + deterministic →
/// unit-testable.
enum TableOfContents {
    static func generate(_ text: String) -> String? {
        let heads = HeadingExtractor.extract(text)
        guard !heads.isEmpty else { return nil }
        let base = heads.map(\.level).min() ?? 1
        return heads.map { h in
            let indent = String(repeating: "  ", count: h.level - base)
            return "\(indent)- [\(h.title)](#\(Fathom.Slugifier.slugify(h.title)))"
        }.joined(separator: "\n")
    }
}
