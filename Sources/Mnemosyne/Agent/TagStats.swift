import Foundation

/// Per-label usage counts and which labels tend to appear TOGETHER, for the
/// `tag_stats` tool. Pure + deterministic (operates on each item's tag list), so
/// it's fully unit-testable without a store.
enum TagStats {
    /// How many items carry each label, most-used first (ties broken alphabetically).
    static func counts(_ itemTagLists: [[String]]) -> [(tag: String, count: Int)] {
        var c: [String: Int] = [:]
        for tags in itemTagLists { for t in Set(tags) { c[t, default: 0] += 1 } }
        return c.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// Label pairs that co-occur on the same item, most-frequent first. Each pair is
    /// ordered (a < b) so it's counted once; deterministic ordering for stable output.
    static func coOccurrences(_ itemTagLists: [[String]], top: Int = 10) -> [(a: String, b: String, count: Int)] {
        var pairs: [String: Int] = [:]
        for tags in itemTagLists {
            let uniq = Array(Set(tags)).sorted()
            guard uniq.count >= 2 else { continue }
            for i in 0..<uniq.count {
                for j in (i + 1)..<uniq.count { pairs["\(uniq[i])\t\(uniq[j])", default: 0] += 1 }
            }
        }
        return pairs.map { kv -> (a: String, b: String, count: Int) in
            let parts = kv.key.components(separatedBy: "\t")
            return (a: parts[0], b: parts[1], count: kv.value)
        }
        .sorted { l, r in
            if l.count != r.count { return l.count > r.count }
            return l.a != r.a ? l.a < r.a : l.b < r.b
        }
        .prefix(top).map { $0 }
    }

    /// Share of the library that carries at least one label. Pure → unit-testable.
    static func coverage(labelled: Int, total: Int) -> (pct: Int, text: String) {
        guard total > 0 else { return (0, "No files yet.") }
        let clamped = Swift.max(0, Swift.min(labelled, total))
        let pct = Int((Double(clamped) / Double(total) * 100).rounded())
        return (pct, "\(pct)% of files labelled (\(clamped) of \(total))")
    }

    /// A readable one/two-line summary: top label counts + the strongest co-occurring
    /// pairs (only those sharing ≥2 items, to skip noise).
    static func summary(_ itemTagLists: [[String]], topLabels: Int = 12, topPairs: Int = 8) -> String {
        let cs = counts(itemTagLists)
        guard !cs.isEmpty else { return "No labels yet." }
        let countText = cs.prefix(topLabels).map { "\($0.tag) (\($0.count))" }.joined(separator: ", ")
        let co = coOccurrences(itemTagLists, top: topPairs).filter { $0.count >= 2 }
        var out = "Labels by use — \(countText)."
        if !co.isEmpty {
            out += "\nOften together — " + co.map { "\($0.a)+\($0.b) (\($0.count))" }.joined(separator: ", ") + "."
        }
        return out
    }
}
