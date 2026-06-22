import Foundation

/// Pulls "Key: Value" METADATA pairs out of a document for the `extract_key_values` tool —
/// note headers, front-matter, `Status: Done` / `Due: Friday` / `Owner: Sam` lines. Pure +
/// deterministic → unit-testable.
///
/// Discrimination: the colon must be followed by whitespace, which cleanly excludes times
/// (`12:30`), ratios (`3:4`), and URLs (`http://…`); the key must start with a letter, be ≤4
/// words, and headings (`#`) are skipped. A leading list bullet is allowed.
enum KeyValueExtractor {
    static func extract(_ text: String, max: Int = 40) -> [(key: String, value: String)] {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(
                pattern: #"^\s*[-*+]?\s*([A-Za-z][A-Za-z0-9 _/\-]{0,31}?)\s*:\s+(\S.*?)\s*$"#)
        else { return [] }

        var out: [(String, String)] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let whole = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: whole),
                  let kr = Range(m.range(at: 1), in: line),
                  let vr = Range(m.range(at: 2), in: line) else { continue }
            let key = String(line[kr]).trimmingCharacters(in: .whitespaces)
            let value = String(line[vr]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, key.split(separator: " ").count <= 4 else { continue }
            let dedupe = key.lowercased()
            if seen.contains(dedupe) { continue }
            seen.insert(dedupe)
            out.append((key, value))
            if out.count >= max { break }
        }
        return out
    }

    /// A tool reply listing each pair, or nil when none are found.
    static func summary(_ text: String, max: Int = 40) -> String? {
        let pairs = extract(text, max: max)
        guard !pairs.isEmpty else { return nil }
        let body = pairs.map { "  \($0.key): \($0.value)" }.joined(separator: "\n")
        return "\(pairs.count) field(s):\n\(body)"
    }
}
