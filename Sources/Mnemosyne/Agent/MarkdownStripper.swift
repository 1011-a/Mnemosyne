import Foundation

/// Strips markdown formatting to plain text for the `strip_markdown` tool — headings, bold/
/// italic, links, images, inline code, list bullets, blockquotes, and horizontal rules. Pure
/// + deterministic → unit-testable. Underscore-italic uses word boundaries so `snake_case`
/// words survive.
enum MarkdownStripper {
    static func strip(_ md: String) -> String {
        // Pass 1: line-level markers (headings, bullets, quotes); skip fenced code fences.
        var lines: [String] = []
        var inFence = false
        for var line in md.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { lines.append(line); continue }
            line = sub(line, #"^\s{0,3}#{1,6}\s+"#, "")        // heading
            line = sub(line, #"^\s*>\s?"#, "")                  // blockquote
            line = sub(line, #"^\s*[-*+]\s+"#, "")              // bullet
            line = sub(line, #"^\s*\d+[.)]\s+"#, "")            // numbered
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")

        // Pass 2: inline markers (order matters).
        text = sub(text, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")      // image → alt (before link)
        text = sub(text, #"\[([^\]]*)\]\([^)]*\)"#, "$1")       // link → text
        text = sub(text, #"\*\*(.+?)\*\*"#, "$1")               // bold *
        text = sub(text, #"__(.+?)__"#, "$1")                   // bold _
        text = sub(text, #"\*(.+?)\*"#, "$1")                   // italic *
        text = sub(text, #"(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])"#, "$1")  // italic _ (snake-safe)
        text = sub(text, #"`([^`]+)`"#, "$1")                   // inline code
        text = sub(text, #"(?m)^\s*([-*_])\1{2,}\s*$"#, "")     // horizontal rule
        return text
    }

    private static func sub(_ s: String, _ pattern: String, _ replacement: String) -> String {
        s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
