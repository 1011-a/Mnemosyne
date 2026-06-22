import Foundation

/// Pulls http(s) URLs out of a document's text for the `extract_links` tool. Pure +
/// deterministic → unit-testable. Strips trailing punctuation, de-dupes, preserves
/// first-seen order.
enum LinkExtractor {
    static func extract(_ text: String, max: Int = 100) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: m.range)
            // Trailing sentence/wrapper punctuation isn't part of the URL.
            while let last = url.last, ".,;:!?\u{2019}\"'".contains(last) { url.removeLast() }
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            out.append(url)
            if out.count >= max { break }
        }
        return out
    }
}
