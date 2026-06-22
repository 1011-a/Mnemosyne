import Foundation

/// Pulls fenced CODE BLOCKS out of a markdown/text document for the `extract_code_blocks`
/// tool — "show me the code snippets in this file", build a snippet library. Recognizes
/// triple-backtick fences with an optional language tag (```swift … ```). Pure +
/// deterministic → unit-testable. Returns each block's language (may be empty) and body,
/// in document order; empty blocks are skipped.
enum CodeBlockExtractor {
    static func extract(_ text: String, max: Int = 40) -> [(language: String, code: String)] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var out: [(String, String)] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                let code = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty {
                    out.append((language, code))
                    if out.count >= max { break }
                }
            }
            i += 1
        }
        return out
    }

    /// A tool reply listing each block (language + line count) with a short preview, or nil
    /// when there are none. Each block is clamped so one huge snippet can't dominate.
    static func summary(_ text: String, previewLines: Int = 12, max: Int = 40) -> String? {
        let blocks = extract(text, max: max)
        guard !blocks.isEmpty else { return nil }
        let parts = blocks.enumerated().map { idx, b -> String in
            let lines = b.code.components(separatedBy: "\n")
            let shown = lines.prefix(previewLines).joined(separator: "\n")
            let more = lines.count > previewLines ? "\n…(+\(lines.count - previewLines) more lines)" : ""
            let lang = b.language.isEmpty ? "code" : b.language
            return "[\(idx + 1)] \(lang) (\(lines.count) line\(lines.count == 1 ? "" : "s")):\n```\(b.language)\n\(shown)\(more)\n```"
        }
        return "\(blocks.count) code block(s):\n" + parts.joined(separator: "\n\n")
    }
}
