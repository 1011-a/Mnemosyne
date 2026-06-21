import Foundation

/// Detects near-duplicate labels ("ml" / "machine-learning" / "ML", "note" /
/// "notes") so the agent can proactively offer a one-tap merge. Pure + deterministic
/// — feeds both the autonomous suggestions and (later) an inline cleanup card.
enum TagCleanup {
    /// Canonical key for fuzzy matching: lowercase, drop separators (- _ space),
    /// and strip a trailing plural 's' on longer words (so "notes"→"note" but
    /// "css"/"ios" stay intact).
    static func canonical(_ tag: String) -> String {
        var s = tag.lowercased()
        for sep in ["-", "_", " ", "."] { s = s.replacingOccurrences(of: sep, with: "") }
        if s.count > 3, s.hasSuffix("s") { s = String(s.dropLast()) }
        return s
    }

    /// Clusters of ≥2 distinct labels that share a canonical form. Within a cluster,
    /// labels are ordered by descending use-count (so the first is the natural merge
    /// target); clusters are ordered largest-first, then alphabetically — fully
    /// deterministic for stable UI + tests.
    static func nearDuplicateClusters(_ tags: [(String, Int)]) -> [[String]] {
        var groups: [String: [(label: String, count: Int)]] = [:]
        for (label, count) in tags {
            let key = canonical(label)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append((label, count))
        }
        var out: [[String]] = []
        for (_, members) in groups where members.count >= 2 {
            let ordered = members
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label.lowercased() < $1.label.lowercased() }
                .map(\.label)
            out.append(ordered)
        }
        return out.sorted { a, b in
            a.count != b.count ? a.count > b.count : (a.first ?? "") < (b.first ?? "")
        }
    }
}
