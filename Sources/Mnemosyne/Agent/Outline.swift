import Foundation

/// Extracts a heading/section outline (a table of contents) from a document's text,
/// for the `outline_item` tool. Recognizes Markdown ATX headings (`#`…`######`),
/// numbered sections ("1. Intro", "2.3 Methods"), and ALL-CAPS header lines. Pure +
/// deterministic → unit-testable.
enum Outline {
    struct Heading: Equatable { let level: Int; let title: String }

    static func extract(_ text: String, max: Int = 60) -> [Heading] {
        var out: [Heading] = []
        for raw in text.components(separatedBy: "\n") {
            guard out.count < max else { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let h = atxHeading(line) ?? numberedHeading(line) ?? allCapsHeading(line) { out.append(h) }
        }
        return out
    }

    /// Markdown ATX: leading 1–6 `#` then the title (trailing `#` trimmed).
    static func atxHeading(_ line: String) -> Heading? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for c in line { if c == "#" { level += 1 } else { break } }
        guard level <= 6, line.count > level else { return nil }
        // The char after the hashes must be a space (so "#hashtag" isn't a heading).
        let after = line[line.index(line.startIndex, offsetBy: level)]
        guard after == " " || after == "\t" else { return nil }
        let title = String(line.dropFirst(level)).trimmingCharacters(in: CharacterSet(charactersIn: " #\t"))
        return title.isEmpty ? nil : Heading(level: level, title: title)
    }

    /// "1. Introduction", "2.3 Methods" — dotted number, then a Title-cased phrase.
    static func numberedHeading(_ line: String) -> Heading? {
        guard let sp = line.firstIndex(of: " ") else { return nil }
        let numPart = String(line[..<sp])
        let rest = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
        let core = numPart.hasSuffix(".") ? String(numPart.dropLast()) : numPart
        let comps = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !comps.isEmpty, comps.count <= 6,
              comps.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        // Heading-like title: short, starts uppercase, not a sentence (no trailing '.').
        guard rest.count >= 2, rest.count <= 60, let f = rest.first, f.isUppercase,
              !rest.hasSuffix(".") else { return nil }
        return Heading(level: comps.count, title: rest)
    }

    /// A short ALL-CAPS line like "INTRODUCTION" or "RELATED WORK".
    static func allCapsHeading(_ line: String) -> Heading? {
        guard line.count >= 2, line.count <= 60, !line.hasSuffix(".") else { return nil }
        let letters = line.filter { $0.isLetter }
        guard letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) else { return nil }
        return Heading(level: 1, title: line)
    }

    /// Indented bullet rendering of an outline (2 spaces per level).
    static func render(_ headings: [Heading]) -> String {
        headings.map { String(repeating: "  ", count: Swift.max(0, $0.level - 1)) + "• " + $0.title }
            .joined(separator: "\n")
    }
}
