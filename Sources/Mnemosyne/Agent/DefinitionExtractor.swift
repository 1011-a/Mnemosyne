import Foundation

/// Pulls DEFINITION sentences out of a document for the `extract_definitions` tool — build a
/// glossary from notes ("HTTP stands for …", "A vector is an …", "X means Y"). Distinct from
/// `define_term` (a single model lookup); this is a pure offline pass. Pure + deterministic →
/// unit-testable. Reuses `ExtractiveSummary.sentences`.
enum DefinitionExtractor {
    /// Subjects that signal an assertion, not a definition ("She is the boss").
    private static let pronouns: Set<String> = [
        "she", "he", "it", "they", "this", "that", "there", "we", "you", "i",
        "these", "those", "who", "what", "here",
    ]

    /// Ordered so multi-word/strong triggers match before the weaker `is a` / `is the`.
    private static let trigger = #"(means|refers to|is defined as|stands for|is an?|are an?|is the|are the)"#

    static func extract(_ text: String, max: Int = 40) -> [(term: String, definition: String)] {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(
                pattern: #"^([A-Za-z][A-Za-z0-9 /\-]{1,49}?)\s+\#(trigger)\s+(.+)$"#,
                options: [.caseInsensitive])
        else { return [] }

        var out: [(String, String)] = []
        var seen = Set<String>()
        for sentence in ExtractiveSummary.sentences(text) {
            let s = sentence.trimmingCharacters(in: .whitespaces)
            let whole = NSRange(s.startIndex..., in: s)
            guard let m = re.firstMatch(in: s, range: whole),
                  let tr = Range(m.range(at: 1), in: s),
                  let gr = Range(m.range(at: 2), in: s),
                  let dr = Range(m.range(at: 3), in: s) else { continue }
            let term = String(s[tr]).trimmingCharacters(in: .whitespaces)
            guard term.split(separator: " ").count <= 5,
                  !pronouns.contains(term.lowercased()) else { continue }
            let definition = (String(s[gr]) + " " + String(s[dr]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " .")) // drop trailing period
            let key = term.lowercased()
            if seen.contains(key) || definition.isEmpty { continue }
            seen.insert(key)
            out.append((term, definition))
            if out.count >= max { break }
        }
        return out
    }

    static func summary(_ text: String, max: Int = 40) -> String? {
        let defs = extract(text, max: max)
        guard !defs.isEmpty else { return nil }
        let body = defs.map { "  \($0.term) — \($0.definition)" }.joined(separator: "\n")
        return "\(defs.count) definition(s):\n\(body)"
    }
}
