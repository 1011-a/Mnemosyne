import Foundation

/// A correct CSV/TSV parser for the `inspect_csv` tool — spreadsheets are common ingested
/// content, and a naive `split(",")` corrupts any field with an embedded comma, quote, or
/// newline. Follows RFC-4180: double-quoted fields may contain the delimiter and newlines,
/// and `""` inside a quoted field is a literal quote. Pure + deterministic → unit-testable.
enum DelimitedParser {

    /// Parse delimited text into records of fields. Fully-empty records (blank lines) are
    /// dropped so a trailing newline doesn't yield a phantom row.
    ///
    /// Iterates over Unicode scalars rather than `Character`s on purpose: Swift treats `\r\n`
    /// as a single grapheme cluster, so a `Character` walk never sees a bare `\n` and CRLF
    /// files wouldn't split into rows.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        guard !text.isEmpty else { return [] }
        let delim = delimiter.unicodeScalars.first!
        let quote: Unicode.Scalar = "\""
        let newline: Unicode.Scalar = "\n"
        let carriage: Unicode.Scalar = "\r"
        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func endField() { record.append(field); field = "" }
        func endRecord() {
            endField()
            if !(record.count == 1 && record[0].isEmpty) { rows.append(record) }
            record = []
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count, scalars[i + 1] == quote { field.unicodeScalars.append(quote); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case quote: inQuotes = true
                case delim: endField()
                case newline: endRecord()
                case carriage: break   // swallow CR (handles CRLF line endings)
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        // Flush the final field/record when the text doesn't end in a newline.
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return rows
    }

    /// Guess the delimiter from the first line: tab if tabs dominate, else comma.
    static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
        let tabs = firstLine.filter { $0 == "\t" }.count
        let commas = firstLine.filter { $0 == "," }.count
        return tabs > commas ? "\t" : ","
    }

    /// A tool reply describing the sheet (delimiter, dimensions, header columns, preview rows),
    /// or nil when nothing parses. Rows are clamped so a big sheet can't dominate the result.
    static func summary(_ text: String, previewRows: Int = 5) -> String? {
        let delim = detectDelimiter(text)
        let rows = parse(text, delimiter: delim)
        guard let header = rows.first else { return nil }
        let data = Array(rows.dropFirst())
        let delimName = delim == "\t" ? "TSV (tab)" : "CSV (comma)"
        let cols = "Columns (\(header.count)): " + header.joined(separator: " | ")
        let shown = data.prefix(previewRows).map { "  " + $0.joined(separator: " | ") }
        let more = data.count > previewRows ? ["  …(+\(data.count - previewRows) more rows)"] : []
        let body = (shown + more).joined(separator: "\n")
        return "\(delimName) — \(header.count) cols × \(data.count) data rows\n\(cols)\n\(body)"
    }
}
