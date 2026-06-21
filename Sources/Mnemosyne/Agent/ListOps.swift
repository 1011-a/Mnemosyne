import Foundation

/// Set operations between two newline-separated lists for the `compare_lists` tool —
/// intersection / difference / union ("what's in A but not B?"). Results are de-duplicated
/// and sorted for determinism. Pure → unit-testable.
enum ListOps {
    /// `op`: common | only_a | only_b | union. Returns sorted unique results, or nil if `op`
    /// is unrecognized.
    static func compare(_ a: String, _ b: String, op: String) -> [String]? {
        let sA = Set(lines(a)), sB = Set(lines(b))
        let result: Set<String>
        switch op.lowercased() {
        case "common", "intersection": result = sA.intersection(sB)
        case "only_a", "difference": result = sA.subtracting(sB)
        case "only_b": result = sB.subtracting(sA)
        case "union": result = sA.union(sB)
        default: return nil
        }
        return result.sorted()
    }

    static func lines(_ s: String) -> [String] {
        s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
