import Foundation

/// Parses YAML-style FRONTMATTER for the `read_frontmatter` tool — the `---`-fenced metadata
/// block at the top of a markdown note (Obsidian, Jekyll, etc.). Distinct from
/// `KeyValueExtractor` (which scans the whole doc); this reads only the leading block. Pure +
/// deterministic → unit-testable.
enum Frontmatter {
    /// Returns the `key: value` pairs in the leading `---` block, or nil if the text doesn't
    /// open with `---` and close with a matching `---`.
    static func parse(_ text: String) -> [(key: String, value: String)]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var pairs: [(String, String)] = []
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { return pairs }   // closing fence
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = stripQuotes(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                if !key.isEmpty { pairs.append((key, value)) }
            }
            i += 1
        }
        return nil   // no closing fence → not frontmatter
    }

    static func summary(_ text: String) -> String? {
        guard let pairs = parse(text), !pairs.isEmpty else { return nil }
        let body = pairs.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
        return "Frontmatter (\(pairs.count) field(s)):\n\(body)"
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        for q: Character in ["\"", "'"] where s.first == q && s.last == q {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
