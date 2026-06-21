import SwiftUI

/// Styles inline citation markers — `[1]`, `[2, 3]` — within answer prose so they
/// read as live references in the accent colour, while the surrounding text keeps
/// the Text's own font. Pure; `attributed` is unit-testable.
enum CitationMarkup {
    private static let pattern = try! NSRegularExpression(pattern: #"\[\d+(?:\s*,\s*\d+)*\]"#)

    /// An AttributedString with each `[N]` marker coloured `accent` and bold; all
    /// other runs are left unstyled so they inherit the surrounding Text font.
    static func attributed(_ text: String, accent: Color) -> AttributedString {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return inlineMarkdown(text) }

        var out = AttributedString()
        var cursor = 0
        for m in matches {
            let r = m.range
            if r.location > cursor {
                out += inlineMarkdown(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            }
            var marker = AttributedString(ns.substring(with: r))
            marker.foregroundColor = accent
            marker.inlinePresentationIntent = .stronglyEmphasized
            out += marker
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out += inlineMarkdown(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return out
    }

    /// Render inline markdown (**bold**, *italic*, `code`, links) within a text run,
    /// preserving whitespace. Falls back to plain text when there's no markup or it
    /// can't parse — so plain prose is never altered.
    static func inlineMarkdown(_ s: String) -> AttributedString {
        guard s.contains("*") || s.contains("`") || s.contains("[") || s.contains("__") else {
            return AttributedString(s)
        }
        return (try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    /// Number of distinct citation-marker runs (test helper).
    static func markerCount(_ text: String) -> Int {
        pattern.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
