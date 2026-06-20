import Foundation

/// Extracts readable text from RFC-822 `.eml` and Apple Mail `.emlx` files:
/// the key headers (Subject/From/To/Date) plus the body, HTML stripped.
enum EmailExtractor {
    static func extract(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return parse(utf8) }
        if let latin = try? String(contentsOf: url, encoding: .isoLatin1) { return parse(latin) }
        let data = try Data(contentsOf: url)
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")

        // .emlx prefixes the message with a byte-count line and appends a plist.
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil {
            lines.removeFirst()
            text = lines.joined(separator: "\n")
        }
        if let r = text.range(of: "\n<?xml") { text = String(text[..<r.lowerBound]) }

        // Split headers / body at the first blank line.
        guard let sep = text.range(of: "\n\n") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let headerBlock = String(text[..<sep.lowerBound])
        var body = String(text[sep.upperBound...])

        let headers = parseHeaders(headerBlock)
        if (headers["content-type"] ?? "").lowercased().contains("text/html") {
            body = stripHTML(body)
        }

        var out: [String] = []
        for key in ["subject", "from", "to", "date"] {
            if let v = headers[key], !v.isEmpty { out.append("\(key.capitalized): \(v)") }
        }
        out.append("")
        out.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse headers, unfolding continuation lines (leading whitespace). Lowercased keys.
    private static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in block.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", let k = currentKey {
                headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
            }
        }
        return headers
    }

    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?s)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                          options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }
}
