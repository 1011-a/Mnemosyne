import Foundation

/// Word-overlap similarity between two texts for the `text_similarity` tool — the Jaccard
/// index over their word sets (0…1). A "how alike are these?" measure, complementing the diff
/// tools (which list the changes). Pure + deterministic → unit-testable.
enum Similarity {
    static func jaccard(_ a: String, _ b: String) -> Double {
        let sa = words(a), sb = words(b)
        if sa.isEmpty, sb.isEmpty { return 1.0 }
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(sa.intersection(sb).count) / Double(union)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}
