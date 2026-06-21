import Foundation

/// Pulls email ADDRESSES out of a document for the `extract_emails` tool (finding
/// contacts). Distinct from `EmailExtractor` (which parses .eml files). Pure +
/// deterministic → unit-testable; distinct, lowercased, in document order; trims
/// trailing punctuation.
enum EmailAddressExtractor {
    static func extract(_ text: String, max: Int = 100) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var e = ns.substring(with: m.range).lowercased()
            while let last = e.last, ".,;:".contains(last) { e.removeLast() }
            guard e.contains("@"), seen.insert(e).inserted else { continue }
            out.append(e)
            if out.count >= max { break }
        }
        return out
    }
}
