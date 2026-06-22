import Foundation

/// Pulls monetary AMOUNTS and PERCENTAGES out of a document for the `extract_figures`
/// tool — answer "what amounts / figures are in this invoice / contract / report". Pure
/// + deterministic → unit-testable. Returns distinct figures in document order, each
/// tagged with its kind (currency or percent).
enum FigureExtractor {
    enum Kind: String, Sendable { case currency, percent }

    static func extract(_ text: String, max: Int = 80) -> [(value: String, kind: Kind)] {
        // A number with optional thousands separators and decimals: 1,234.56 / 50 / 3.5
        let number = #"\d{1,3}(?:,\d{3})*(?:\.\d+)?|\d+(?:\.\d+)?"#
        let patterns: [(String, Kind)] = [
            // Symbol-prefixed currency: $1,234.56  €50  £10  ¥1000
            ("[$€£¥]\\s?(?:\(number))", .currency),
            // Number followed by a currency word/code: 1,234.56 USD / 50 dollars / 10 euros
            ("(?:\(number))\\s?(?:USD|EUR|GBP|JPY|dollars?|euros?|pounds?|yen)\\b", .currency),
            // Percentages: 15% / 3.5 %
            ("(?:\(number))\\s?%", .percent),
        ]
        let ns = text as NSString
        var hits: [(loc: Int, value: String, kind: Kind)] = []
        for (p, kind) in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "  ", with: " ")
                hits.append((m.range.location, raw, kind))
            }
        }
        hits.sort { $0.loc < $1.loc }
        var out: [(value: String, kind: Kind)] = []
        var seen = Set<String>()
        for h in hits where seen.insert(h.value.lowercased() + "|" + h.kind.rawValue).inserted {
            out.append((h.value, h.kind))
            if out.count >= max { break }
        }
        return out
    }

    /// Group figures into "Amounts" / "Percentages" lines for a tool reply, or nil when
    /// none were found.
    static func summary(_ text: String, max: Int = 80) -> String? {
        let figs = extract(text, max: max)
        guard !figs.isEmpty else { return nil }
        func line(_ label: String, _ kind: Kind) -> String? {
            let vals = figs.filter { $0.kind == kind }.map(\.value)
            return vals.isEmpty ? nil : "\(label): " + vals.joined(separator: ", ")
        }
        return [line("Amounts", .currency), line("Percentages", .percent)]
            .compactMap { $0 }.joined(separator: "\n")
    }
}
