import Foundation

/// Formats agent-provided rows into an aligned GitHub-markdown table for the `make_table`
/// tool — present a list/result cleanly in the chat. Rows are newline-separated; cells are
/// pipe- or comma-separated (auto-detected). The first row is the header. Pure +
/// deterministic → unit-testable.
enum MarkdownTable {
    static func make(_ data: String) -> String? {
        let lines = data.split(whereSeparator: { $0 == "\n" }).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }

        let delim: Character = lines.contains(where: { $0.contains("|") }) ? "|" : ","
        return tableFrom(lines.map { cells($0, delim: delim) })
    }

    /// Build an aligned markdown table from already-parsed rows (first row = header). Shared
    /// by `make` and the `csv_to_table` tool. Nil if there are no rows/columns.
    static func tableFrom(_ rows: [[String]]) -> String? {
        guard !rows.isEmpty else { return nil }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }

        // Pad ragged rows so every row has the same number of columns.
        let padded = rows.map { row -> [String] in
            row + Array(repeating: "", count: columns - row.count)
        }
        // Column widths (≥3 so the `---` separator renders).
        var widths = [Int](repeating: 3, count: columns)
        for row in padded {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }

        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated()
                .map { i, c in c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: " | ") + " |"
        }

        let header = line(padded[0])
        let separator = "| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |"
        let body = padded.dropFirst().map(line)
        return ([header, separator] + body).joined(separator: "\n")
    }

    /// Split a row into trimmed cells (leading/trailing delimiter optional).
    static func cells(_ line: String, delim: Character) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.first == delim { s.removeFirst() }
        if s.last == delim { s.removeLast() }
        return s.split(separator: delim, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
