import Foundation

/// Pulls ACRONYMS / initialisms out of a document for the `extract_acronyms` tool — build
/// a glossary or decode jargon in a technical/research file. An acronym here is an
/// uppercase token of 2–6 characters starting with a letter (letters + digits allowed,
/// e.g. API, HTTP, TCP, JSON, S3, HTTP2). Pure + deterministic → unit-testable. Distinct,
/// in document order.
enum AcronymExtractor {
    static func extract(_ text: String, max: Int = 60) -> [String] {
        guard !text.isEmpty, let re = try? NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]{1,5}\b"#) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let a = ns.substring(with: m.range)
            if seen.insert(a).inserted {
                out.append(a)
                if out.count >= max { break }
            }
        }
        return out
    }

    /// One-line tool reply ("API, HTTP, JSON, TCP, IP"), or nil when none were found.
    static func summary(_ text: String, max: Int = 60) -> String? {
        let items = extract(text, max: max)
        return items.isEmpty ? nil : items.joined(separator: ", ")
    }
}
