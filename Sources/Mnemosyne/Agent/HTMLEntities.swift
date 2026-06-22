import Foundation

/// Escapes/unescapes HTML entities for the `html_entities` tool — make text safe for HTML, or
/// decode entity-encoded text. Pure + deterministic → unit-testable. Ordering matters so the
/// two are exact inverses (escape does `&` first; unescape does `&amp;` last).
enum HTMLEntities {
    static func escape(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&#39;")
        return r
    }

    static func unescape(_ s: String) -> String {
        var r = s
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            r = r.replacingOccurrences(of: entity, with: char)
        }
        return r
    }
}
