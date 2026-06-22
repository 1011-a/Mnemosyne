import Foundation

/// Line-level diff between two text blocks for the `line_diff` tool — a unified-style view of what
/// changed between two versions (unchanged lines prefixed " ", removed "-", added "+"). Uses a
/// longest-common-subsequence DP so unchanged regions are matched optimally, not just position by
/// position. Pure + deterministic → unit-testable. Distinct from `word_diff` (intra-line words).
enum LineDiff {
    struct Result {
        let lines: [String]   // each prefixed with " ", "-", or "+"
        let added: Int
        let removed: Int
    }

    static func diff(_ a: String, _ b: String) -> Result {
        let aLines = a.components(separatedBy: "\n")
        let bLines = b.components(separatedBy: "\n")
        let n = aLines.count, m = bLines.count

        // LCS length table.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = aLines[i] == bLines[j]
                        ? lcs[i + 1][j + 1] + 1
                        : Swift.max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // Walk the table to emit the diff.
        var out: [String] = [], added = 0, removed = 0
        var i = 0, j = 0
        while i < n && j < m {
            if aLines[i] == bLines[j] {
                out.append("  " + aLines[i]); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append("- " + aLines[i]); removed += 1; i += 1
            } else {
                out.append("+ " + bLines[j]); added += 1; j += 1
            }
        }
        while i < n { out.append("- " + aLines[i]); removed += 1; i += 1 }
        while j < m { out.append("+ " + bLines[j]); added += 1; j += 1 }
        return Result(lines: out, added: added, removed: removed)
    }
}
