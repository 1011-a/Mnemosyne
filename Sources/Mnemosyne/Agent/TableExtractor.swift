import Foundation

/// Pulls markdown TABLES out of a document for the `extract_tables` tool — tables hold a
/// doc's densest structured data (specs, schedules, comparisons, pricing). Recognizes the
/// GitHub-flavored form: a header row, a `|---|:--:|` separator, then data rows. Pure +
/// deterministic → unit-testable.
enum TableExtractor {
    struct Table: Equatable {
        let headers: [String]
        let rows: [[String]]
    }

    static func extract(_ text: String, max: Int = 20) -> [Table] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var tables: [Table] = []
        var i = 0
        while i < lines.count {
            if isRow(lines[i]), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                let headers = cells(lines[i])
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, isRow(lines[j]), !isSeparator(lines[j]) {
                    rows.append(cells(lines[j]))
                    j += 1
                }
                tables.append(Table(headers: headers, rows: rows))
                if tables.count >= max { break }
                i = j
            } else {
                i += 1
            }
        }
        return tables
    }

    /// A row is any non-empty line containing a pipe.
    static func isRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.contains("|")
    }

    /// A separator is a row whose every cell is only dashes/colons (e.g. `---`, `:--:`).
    static func isSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cs = cells(line)
        guard !cs.isEmpty else { return false }
        return cs.allSatisfy { c in
            let t = c.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Split a `| a | b |` row into trimmed cells (leading/trailing pipes optional).
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A tool reply describing each table (dimensions + headers + a few preview rows), or nil
    /// when there are none. Rows are clamped so a long table can't dominate the result.
    static func summary(_ text: String, previewRows: Int = 5, max: Int = 20) -> String? {
        let tables = extract(text, max: max)
        guard !tables.isEmpty else { return nil }
        let parts = tables.enumerated().map { idx, t -> String in
            let header = "[" + t.headers.joined(separator: " | ") + "]"
            let shown = t.rows.prefix(previewRows).map { "  " + $0.joined(separator: " | ") }
            let more = t.rows.count > previewRows ? "  …(+\(t.rows.count - previewRows) more rows)" : nil
            let body = (shown + [more].compactMap { $0 }).joined(separator: "\n")
            return "Table \(idx + 1) (\(t.headers.count) cols × \(t.rows.count) rows):\n\(header)\n\(body)"
        }
        return "\(tables.count) table(s):\n" + parts.joined(separator: "\n\n")
    }
}
