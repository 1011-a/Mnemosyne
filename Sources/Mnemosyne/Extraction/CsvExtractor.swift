import Foundation

/// Turns a `.csv` / `.tsv` table into readable, searchable rows — each data row
/// becomes "header: value · header: value …" using the first row as headers — so
/// a spreadsheet export answers questions ("what's Alice's email?") instead of
/// being an opaque comma soup. Pure; `parse` is unit-testable on a raw string.
/// Handles quoted fields (commas/newlines inside quotes) and "" escapes.
enum CsvExtractor {
    static func isCsv(_ url: URL) -> Bool {
        ["csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    static func extract(_ url: URL) throws -> String {
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        return parse(try String(contentsOf: url, encoding: .utf8), delimiter: delimiter)
    }

    static func parse(_ text: String, delimiter: Character = ",") -> String {
        let records = records(text, delimiter: delimiter)
            .filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard let header = records.first else { return "" }
        let headers = header.map { $0.trimmingCharacters(in: .whitespaces) }
        let dataRows = records.dropFirst()
        guard !dataRows.isEmpty else { return headers.joined(separator: " · ") }

        var lines: [String] = []
        for row in dataRows {
            var parts: [String] = []
            for (i, raw) in row.enumerated() {
                let value = raw.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                let key = i < headers.count && !headers[i].isEmpty ? headers[i] : "col\(i + 1)"
                parts.append("\(key): \(value)")
            }
            if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        }
        return lines.joined(separator: "\n")
    }

    /// Split delimited text into records of fields, honouring quoted fields.
    private static func records(_ text: String, delimiter: Character) -> [[String]] {
        var out: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i += 1
            } else {
                switch c {
                case "\"":      inQuotes = true
                case delimiter: record.append(field); field = ""
                case "\r":      break
                case "\n":      record.append(field); out.append(record); field = ""; record = []
                default:        field.append(c)
                }
                i += 1
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); out.append(record) }
        return out
    }
}
