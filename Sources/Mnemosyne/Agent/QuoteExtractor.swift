import Foundation

/// Pulls quoted passages out of a document for the `extract_quotes` tool — find citations or
/// highlighted lines in a note. Handles straight ("…") and smart ("…") quotes. Pure +
/// deterministic → unit-testable.
enum QuoteExtractor {
    static func extract(_ text: String, max: Int = 30) -> [String] {
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        let ns = text as NSString
        // A quoted span can't contain its own delimiter, so a simple class works.
        for pattern in [#""([^"]{2,})""#, "\u{201C}([^\u{201D}]{2,})\u{201D}"] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let q = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if q.count >= 2, seen.insert(q).inserted {
                    out.append(q)
                    if out.count >= max { return out }
                }
            }
        }
        return out
    }

    static func summary(_ text: String, max: Int = 30) -> String? {
        let quotes = extract(text, max: max)
        guard !quotes.isEmpty else { return nil }
        let body = quotes.map { "  “\($0)”" }.joined(separator: "\n")
        return "\(quotes.count) quote(s):\n\(body)"
    }
}
