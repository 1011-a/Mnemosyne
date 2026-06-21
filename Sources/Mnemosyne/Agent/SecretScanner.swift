import Foundation

/// Scans text for leaked CREDENTIALS for the `scan_secrets` tool — API keys, access tokens,
/// and private keys that shouldn't live in a note or pasted config. Distinct from `Redactor`
/// (which masks contact PII). Findings are reported with the secret MASKED so the scan result
/// itself never leaks. Pure + deterministic → unit-testable.
enum SecretScanner {
    struct Finding: Equatable {
        let type: String
        let masked: String
    }

    /// Specific patterns first, generic assignment last.
    private static let rules: [(type: String, pattern: String)] = [
        ("AWS access key", #"AKIA[0-9A-Z]{16}"#),
        ("Google API key", #"AIza[0-9A-Za-z_\-]{35}"#),
        ("GitHub token", #"gh[pousr]_[A-Za-z0-9]{36}"#),
        ("Slack token", #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
        ("private key", #"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#),
        ("generic secret", #"(?i)(?:api[_-]?key|secret|token|password)\s*[:=]\s*["']?[A-Za-z0-9_\-]{12,}"#),
    ]

    static func scan(_ text: String) -> [Finding] {
        guard !text.isEmpty else { return [] }
        var out: [Finding] = []
        var seen = Set<String>()
        let ns = text as NSString
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let match = ns.substring(with: m.range)
                let dedupe = rule.type + "|" + match
                if seen.contains(dedupe) { continue }
                seen.insert(dedupe)
                out.append(Finding(type: rule.type, masked: mask(match)))
            }
        }
        return out
    }

    /// Show just enough to recognize a finding without revealing it (or its length).
    static func mask(_ s: String) -> String {
        if s.contains("PRIVATE KEY") { return "<PEM private key header>" }
        return String(s.prefix(4)) + "****"
    }

    /// A tool reply listing masked findings (clamped), or nil when the text looks clean.
    static func report(_ text: String, max: Int = 20) -> String? {
        let findings = scan(text)
        guard !findings.isEmpty else { return nil }
        let shown = findings.prefix(max).map { "  - \($0.type): \($0.masked)" }
        let more = findings.count > max ? ["  …(+\(findings.count - max) more)"] : []
        return "⚠️ Found \(findings.count) potential secret(s):\n" + (shown + more).joined(separator: "\n")
    }
}
