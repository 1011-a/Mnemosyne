import Foundation

/// Sorts the lines of a block of text for the `sort_lines` tool — tidy a list (names, values),
/// optionally numerically, reversed, and/or de-duplicated. Pure + deterministic → unit-testable.
enum LineSorter {
    static func sort(_ text: String, descending: Bool = false,
                     unique: Bool = false, numeric: Bool = false) -> String {
        var lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if numeric {
            // Numeric order; non-numbers fall back to a stable lexicographic position.
            lines.sort { a, b in
                switch (Double(a), Double(b)) {
                case let (x?, y?): return x != y ? x < y : a < b
                case (nil, _?): return false        // numbers before non-numbers
                case (_?, nil): return true
                default: return a < b
                }
            }
        } else {
            lines.sort { a, b in
                let la = a.lowercased(), lb = b.lowercased()
                return la != lb ? la < lb : a < b
            }
        }

        if unique {
            var seen = Set<String>()
            lines = lines.filter { seen.insert($0).inserted }
        }
        if descending { lines.reverse() }
        return lines.joined(separator: "\n")
    }
}
