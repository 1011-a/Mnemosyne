import Foundation

/// A parsed block of an assistant answer, so the UI can compose a rich
/// "generative card" instead of a flat wall of text.
/// One label→value pair, rendered as a compact stat tile.
struct AnswerStat: Equatable, Sendable {
    let label: String
    let value: String
}

enum AnswerBlock: Equatable, Sendable {
    case heading(String)     // a section label  ("## …" or "**…**" line)
    case lead(String)        // the opening summary sentence (first paragraph)
    case bullet(String)      // a key point ("- ", "* ", "• ", "1. ")
    case paragraph(String)   // ordinary prose
    case table(headers: [String], rows: [[String]])  // a markdown table → mini-table
    case stats([AnswerStat]) // a run of "Label: value" lines → stat tiles
    case code(String)        // a ```fenced``` block → monospaced
    case quote(String)       // a run of "> …" lines → styled blockquote
}

enum AnswerFormat {
    /// Parse markdown-ish answer text into ordered blocks. The first paragraph
    /// becomes the `lead` so the card can headline it. Markdown tables are
    /// lifted out as structured `.table` blocks for visual rendering.
    static func parse(_ text: String) -> [AnswerBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [AnswerBlock] = []
        var paragraph: [String] = []
        var leadAssigned = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            guard !joined.isEmpty else { return }
            if !leadAssigned {
                blocks.append(.lead(joined)); leadAssigned = true
            } else {
                blocks.append(.paragraph(joined))
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); i += 1; continue }

            // A ```fenced``` code block — checked first so its contents aren't
            // mis-parsed as tables/bullets; raw lines keep their indentation.
            if let (code, consumed) = parseCodeFence(lines, from: i) {
                flushParagraph(); blocks.append(code); i += consumed; continue
            }
            // A markdown table: a header row, then a |---|---| separator row.
            if let (table, consumed) = parseTable(lines, from: i) {
                flushParagraph(); blocks.append(table); i += consumed; continue
            }
            // A run of two or more "Label: value" lines → a stat-tile block.
            if let (stats, consumed) = parseStats(lines, from: i) {
                flushParagraph(); blocks.append(stats); i += consumed; continue
            }
            // A run of "> …" lines → a blockquote.
            if let (quote, consumed) = parseQuote(lines, from: i) {
                flushParagraph(); blocks.append(quote); i += consumed; continue
            }
            if let h = heading(line) { flushParagraph(); blocks.append(.heading(h)); i += 1; continue }
            if let b = bullet(line) { flushParagraph(); blocks.append(.bullet(b)); i += 1; continue }
            paragraph.append(line); i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: blockquotes

    /// Collect a run of consecutive "> …" lines into one `.quote` block (markers
    /// and a single following space stripped; lines joined with spaces).
    private static func parseQuote(_ lines: [String], from start: Int) -> (AnswerBlock, Int)? {
        func quoteText(_ raw: String) -> String? {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line == ">" || line.hasPrefix("> ") else { return nil }
            return clean(String(line.dropFirst(line == ">" ? 1 : 2)))
        }
        guard quoteText(lines[start]) != nil else { return nil }
        var parts: [String] = []
        var j = start
        while j < lines.count, let t = quoteText(lines[j]) {
            if !t.isEmpty { parts.append(t) }
            j += 1
        }
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (.quote(text), j - start)
    }

    // MARK: code fences

    /// If a ```fenced``` block starts at `start`, return a `.code` block (raw,
    /// indentation preserved, language tag dropped) and how many lines it spans.
    private static func parseCodeFence(_ lines: [String], from start: Int) -> (AnswerBlock, Int)? {
        guard lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return nil }
        var body: [String] = []
        var j = start + 1
        while j < lines.count {
            if lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                return (.code(body.joined(separator: "\n")), j - start + 1)  // include both fences
            }
            body.append(lines[j])                                            // raw — keep indentation
            j += 1
        }
        return (.code(body.joined(separator: "\n")), j - start)              // unterminated → to end
    }

    // MARK: tables

    /// If a markdown table starts at `start`, return the block and how many lines
    /// it spans. Requires a header row immediately followed by a separator row.
    private static func parseTable(_ lines: [String], from start: Int) -> (AnswerBlock, Int)? {
        guard start + 1 < lines.count,
              let headerCells = rowCells(lines[start]), headerCells.count >= 2,
              let sepCells = rowCells(lines[start + 1]), isSeparator(sepCells)
        else { return nil }

        let headers = headerCells.map(clean)
        let width = headers.count
        var rows: [[String]] = []
        var j = start + 2
        while j < lines.count, let cells = rowCells(lines[j]) {
            var row = cells.map(clean)
            if row.count < width { row += Array(repeating: "", count: width - row.count) }
            else if row.count > width { row = Array(row.prefix(width)) }
            rows.append(row)
            j += 1
        }
        // A 2-column table whose values are all stat-like (and at least one
        // numeric) reads better as metric tiles than a wide table.
        if width == 2, rows.count >= 2,
           rows.allSatisfy({ !$0[0].isEmpty && isStatValue($0[1]) }),
           rows.contains(where: { $0[1].contains(where: \.isNumber) }) {
            let stats = rows.map { AnswerStat(label: $0[0], value: $0[1]) }
            return (.stats(stats), j - start)
        }
        return (.table(headers: headers, rows: rows), j - start)
    }

    /// Split a line into table cells, or nil if it isn't a pipe-delimited row.
    private static func rowCells(_ raw: String) -> [String]? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("|") else { return nil }
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|") { line.removeLast() }
        let cells = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 ? cells : nil
    }

    // MARK: stats

    /// If two or more consecutive "Label: value" lines start at `start`, return
    /// a `.stats` block and how many lines it spans. Conservative on purpose so
    /// ordinary prose with a colon is never mistaken for a metric.
    private static func parseStats(_ lines: [String], from start: Int) -> (AnswerBlock, Int)? {
        var pairs: [AnswerStat] = []
        var j = start
        while j < lines.count, let pair = statPair(lines[j]) {
            pairs.append(pair); j += 1
        }
        guard pairs.count >= 2 else { return nil }
        return (.stats(pairs), j - start)
    }

    /// Parse a single "Label: value" line into a stat, or nil if it isn't one.
    /// A stat has a short label and a short, value-like right-hand side.
    private static func statPair(_ raw: String) -> AnswerStat? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        // Allow a leading bullet marker ("- Total: 88").
        for m in ["- ", "* ", "• ", "– "] where line.hasPrefix(m) { line = String(line.dropFirst(m.count)); break }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = clean(String(line[..<colon]))
        let value = clean(String(line[line.index(after: colon)...]))
        guard !label.isEmpty, !value.isEmpty else { return nil }
        // Label: short, a few words, no sentence punctuation.
        guard label.count <= 30, wordCount(label) <= 5,
              !label.contains(". "), label.last != "." else { return nil }
        guard isStatValue(value) else { return nil }
        return AnswerStat(label: label, value: value)
    }

    /// A short, "stat-like" right-hand side: a number or a single compact token,
    /// never a sentence. Shared by line-stats and 2-column-table → tiles.
    private static func isStatValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 24, wordCount(value) <= 4 else { return false }
        let hasDigit = value.contains { $0.isNumber }
        let compactToken = !value.contains(" ") && value.count <= 14
        guard hasDigit || compactToken else { return false }
        // Reject sentence-like values ("done and shipped.") unless numeric.
        if let last = value.last, ".!?".contains(last), !hasDigit { return false }
        return true
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " }).count
    }

    /// A separator row is all dashes/colons, e.g. `---`, `:--`, `:-:`.
    private static func isSeparator(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            !cell.isEmpty
            && cell.contains("-")
            && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func heading(_ line: String) -> String? {
        if line.hasPrefix("#") {
            return String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
        }
        // A whole line wrapped in ** ** acts as a heading.
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "– "] {
            if line.hasPrefix(marker) { return clean(String(line.dropFirst(marker.count))) }
        }
        // numbered: "1. " / "2) "
        if let first = line.first, first.isNumber {
            let rest = line.drop(while: { $0.isNumber })
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return clean(String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// Strip leading bold "**Label:**" emphasis markers for clean rendering.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}
