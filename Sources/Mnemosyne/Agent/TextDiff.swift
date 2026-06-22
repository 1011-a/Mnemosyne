import Foundation

/// A small, dependency-free line-level diff (LCS-based) used by the `diff_items`
/// tool to turn two versions of a file into a structured changelog the agent can
/// describe. Pure + deterministic → unit-testable.
enum TextDiff {
    enum Op: Equatable { case keep, add, remove }
    struct Line: Equatable { let op: Op; let text: String }

    /// Longest-common-subsequence line diff: unchanged lines are `.keep`, lines only
    /// in `a` are `.remove`, lines only in `b` are `.add`, in original order.
    static func lineDiff(_ a: String, _ b: String) -> [Line] {
        // An empty input is ZERO lines (not one blank line) — otherwise an empty file
        // would read as a removable/addable blank line.
        let aLines = a.isEmpty ? [] : a.components(separatedBy: "\n")
        let bLines = b.isEmpty ? [] : b.components(separatedBy: "\n")
        let n = aLines.count, m = bLines.count
        // dp[i][j] = LCS length of aLines[i...] and bLines[j...].
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = aLines[i] == bLines[j] ? dp[i + 1][j + 1] + 1
                                                      : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var i = 0, j = 0, out: [Line] = []
        while i < n && j < m {
            if aLines[i] == bLines[j] { out.append(Line(op: .keep, text: aLines[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { out.append(Line(op: .remove, text: aLines[i])); i += 1 }
            else { out.append(Line(op: .add, text: bLines[j])); j += 1 }
        }
        while i < n { out.append(Line(op: .remove, text: aLines[i])); i += 1 }
        while j < m { out.append(Line(op: .add, text: bLines[j])); j += 1 }
        return out
    }

    /// A compact changelog: a count header + only the changed lines (`+`/`-`),
    /// unchanged lines omitted, capped at `maxLines`.
    static func changelog(_ a: String, _ b: String, maxLines: Int = 60) -> String {
        let diff = lineDiff(a, b)
        let added = diff.lazy.filter { $0.op == .add }.count
        let removed = diff.lazy.filter { $0.op == .remove }.count
        guard added > 0 || removed > 0 else { return "No line-level differences." }
        var lines: [String] = []
        for d in diff where d.op != .keep {
            lines.append((d.op == .add ? "+ " : "- ") + d.text)
            if lines.count >= maxLines { lines.append("… (truncated)"); break }
        }
        return "\(added) added, \(removed) removed line(s):\n" + lines.joined(separator: "\n")
    }
}
