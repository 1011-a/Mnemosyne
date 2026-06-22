import Foundation

/// Indents or dedents a block of text for the `reindent` tool — add leading spaces, or strip
/// the common leading whitespace (handy for code snippets pulled from a larger file). Pure +
/// deterministic → unit-testable. Blank lines are left untouched (no trailing whitespace).
enum TextIndent {
    static func indent(_ text: String, spaces: Int) -> String {
        let pad = String(repeating: " ", count: max(0, spaces))
        return text.components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : pad + $0 }
            .joined(separator: "\n")
    }

    static func dedent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let leadings = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = leadings.min() ?? 0
        guard common > 0 else { return text }
        return lines.map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? line : String(line.dropFirst(common))
        }.joined(separator: "\n")
    }
}
