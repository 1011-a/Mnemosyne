import Foundation

/// Finds lines in a document containing a query for the `find_in_item` tool — "where does
/// this note mention X?". A focused within-document grep (case-insensitive substring),
/// distinct from cross-item semantic search. Pure + deterministic → unit-testable.
enum LineGrep {
    struct Match: Equatable {
        let lineNumber: Int   // 1-based
        let line: String
    }

    static func search(_ text: String, query: String, max: Int = 50) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [Match] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            if raw.lowercased().contains(q) {
                out.append(Match(lineNumber: i + 1, line: raw.trimmingCharacters(in: .whitespaces)))
                if out.count >= max { break }
            }
        }
        return out
    }

    /// A tool reply listing matching lines (number + clamped text), or nil when none match.
    static func summary(_ text: String, query: String, max: Int = 50) -> String? {
        let matches = search(text, query: query, max: max)
        guard !matches.isEmpty else { return nil }
        let body = matches.map { "  L\($0.lineNumber): \(clamp($0.line))" }.joined(separator: "\n")
        return "\(matches.count) line(s) match '\(query)':\n\(body)"
    }

    private static func clamp(_ s: String, _ limit: Int = 200) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}
