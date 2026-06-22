import Foundation

/// Masks personal identifiers (emails, phone numbers, US SSNs) in text for the `redact_pii`
/// tool — produce a shareable/exportable copy of a note without leaking contact details.
/// Pure + deterministic → unit-testable. Defensive: it only ADDS masking, never reveals.
enum Redactor {
    struct Result: Equatable {
        let text: String
        let counts: [String: Int]   // category → how many were masked
    }

    /// Order matters: emails first, then SSN before phone (an SSN must not be read as a phone).
    private static let rules: [(name: String, pattern: String, replacement: String)] = [
        ("email", #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
        ("ssn", #"\b\d{3}-\d{2}-\d{4}\b"#, "[ssn]"),
        ("phone", #"(?<!\d)(?:\+?\d{1,2}[ .\-]?)?(?:\(\d{3}\)|\d{3})[ .\-]?\d{3}[ .\-]?\d{4}(?!\d)"#, "[phone]"),
    ]

    static func redact(_ text: String) -> Result {
        var s = text
        var counts: [String: Int] = [:]
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(location: 0, length: (s as NSString).length)
            let n = re.numberOfMatches(in: s, range: range)
            guard n > 0 else { continue }
            counts[rule.name] = n
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
        }
        return Result(text: s, counts: counts)
    }

    /// A tool reply: the redacted text (clamped) plus a tally, or nil when nothing was found.
    static func report(_ text: String, maxChars: Int = 1500) -> String? {
        let r = redact(text)
        guard !r.counts.isEmpty else { return nil }
        let total = r.counts.values.reduce(0, +)
        let tally = r.counts.sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let preview = r.text.count > maxChars ? String(r.text.prefix(maxChars)) + "…" : r.text
        return "Redacted \(total) item(s) — \(tally):\n\(preview)"
    }
}
