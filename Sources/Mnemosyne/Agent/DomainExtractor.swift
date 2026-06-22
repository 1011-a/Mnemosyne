import Foundation

/// Pulls the unique DOMAIN names out of a document for the `extract_domains` tool — the hosts
/// from URLs and the domains from email addresses ("which sites appear in my notes?"). Pure +
/// deterministic (sorted unique) → unit-testable. Restricted to URLs/emails to avoid matching
/// things like filenames.
enum DomainExtractor {
    static func extract(_ text: String, max: Int = 200) -> [String] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var set = Set<String>()
        for pattern in [#"https?://([A-Za-z0-9.\-]+)"#, #"@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let host = ns.substring(with: m.range(at: 1)).lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if host.contains(".") { set.insert(host) }
                if set.count >= max { break }
            }
        }
        return set.sorted()
    }

    static func summary(_ text: String, max: Int = 200) -> String? {
        let domains = extract(text, max: max)
        guard !domains.isEmpty else { return nil }
        return "\(domains.count) domain(s):\n" + domains.map { "  \($0)" }.joined(separator: "\n")
    }
}
