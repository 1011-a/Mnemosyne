import Foundation

/// Derives lightweight tags for a newly-ingested file from its folder structure,
/// so the tag system populates itself ("which project/area did this come from").
/// Deterministic and offline — the last couple of meaningful parent directories.
enum AutoTagger {
    /// Generic container names that say nothing useful as tags.
    private static let stopwords: Set<String> = [
        "users", "desktop", "documents", "downloads", "library", "volumes",
        "private", "var", "tmp", "applications", "icloud", "mobile", "containers",
        "com~apple~clouddocs", "shared", "public", "home"
    ]

    static func tags(for url: URL, max: Int = 2) -> [String] {
        let dirs = url.deletingLastPathComponent().pathComponents
        var out: [String] = []
        // Walk from the deepest parent outward, collecting meaningful names.
        for component in dirs.reversed() {
            guard let tag = normalize(component) else { continue }
            if stopwords.contains(tag) { continue }
            if !out.contains(tag) { out.append(tag) }
            if out.count == max { break }
        }
        return out
    }

    /// Lowercase, keep alphanumerics + a couple separators collapsed to one,
    /// trim, and bound the length. Returns nil if nothing usable remains.
    static func normalize(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        var chars: [Character] = []
        var lastWasSep = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                chars.append(ch); lastWasSep = false
            } else if ch == " " || ch == "-" || ch == "_" {
                if !lastWasSep && !chars.isEmpty { chars.append("-"); lastWasSep = true }
            }
        }
        while chars.last == "-" { chars.removeLast() }
        let tag = String(chars.prefix(24))
        // Reject pure-numeric or 1-char tags (years, drive letters, noise).
        guard tag.count >= 2, tag.contains(where: { $0.isLetter }) else { return nil }
        return tag
    }
}
