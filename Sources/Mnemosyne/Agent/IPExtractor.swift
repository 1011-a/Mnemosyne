import Foundation

/// Pulls valid IPv4 addresses out of a document for the `extract_ips` tool — log/config
/// analysis. Each of the four octets is validated to be 0–255 (so `999.1.1.1` is rejected).
/// Pure + deterministic → unit-testable.
enum IPExtractor {
    static func extract(_ text: String, max: Int = 100) -> [String] {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(pattern: #"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b"#)
        else { return [] }
        let ns = text as NSString
        var out: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let octets = (1...4).compactMap { Int(ns.substring(with: m.range(at: $0))) }
            guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { continue }
            let ip = octets.map(String.init).joined(separator: ".")
            if seen.insert(ip).inserted {
                out.append(ip)
                if out.count >= max { break }
            }
        }
        return out
    }

    static func summary(_ text: String, max: Int = 100) -> String? {
        let ips = extract(text, max: max)
        guard !ips.isEmpty else { return nil }
        return "\(ips.count) IPv4 address(es):\n" + ips.map { "  \($0)" }.joined(separator: "\n")
    }
}
