import Foundation

/// Pulls MONETARY AMOUNTS out of a document for the `extract_amounts` tool — receipts,
/// invoices, expense notes — and totals them per currency. Recognizes symbol-prefixed
/// (`$1,200.50`, `€30`) and ISO-code forms (`45 USD`, `USD 45`). Pure + deterministic →
/// unit-testable. Overlapping matches (e.g. `$45 USD`) are counted once.
enum MoneyExtractor {
    struct Amount: Equatable {
        let currency: String
        let value: Double
    }

    private static let codes = "USD|EUR|GBP|JPY|CNY|CAD|AUD|CHF"

    static func extract(_ text: String) -> [Amount] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let number = #"[0-9][0-9,]*(?:\.[0-9]+)?"#
        let patterns: [(String, (NSTextCheckingResult) -> Amount?)] = [
            // $1,200.50  /  €30
            (#"([$€£¥])\s?(\#(number))"#, { m in
                guard let v = parse(ns.substring(with: m.range(at: 2))) else { return nil }
                return Amount(currency: code(forSymbol: ns.substring(with: m.range(at: 1))), value: v)
            }),
            // 45 USD
            (#"(\#(number))\s?(\#(codes))\b"#, { m in
                guard let v = parse(ns.substring(with: m.range(at: 1))) else { return nil }
                return Amount(currency: ns.substring(with: m.range(at: 2)).uppercased(), value: v)
            }),
            // USD 45
            (#"\b(\#(codes))\s?(\#(number))"#, { m in
                guard let v = parse(ns.substring(with: m.range(at: 2))) else { return nil }
                return Amount(currency: ns.substring(with: m.range(at: 1)).uppercased(), value: v)
            }),
        ]

        var hits: [(range: NSRange, amount: Amount)] = []
        for (pat, build) in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let a = build(m) { hits.append((m.range, a)) }
            }
        }
        // Greedily accept non-overlapping matches (left to right) so $45 USD counts once.
        hits.sort { $0.range.location < $1.range.location }
        var out: [Amount] = []
        var consumed = 0
        for h in hits where h.range.location >= consumed {
            out.append(h.amount)
            consumed = h.range.location + h.range.length
        }
        return out
    }

    /// A tool reply totalling amounts per currency, or nil when none are found.
    static func summary(_ text: String) -> String? {
        let amounts = extract(text)
        guard !amounts.isEmpty else { return nil }
        var totals: [String: (sum: Double, count: Int)] = [:]
        for a in amounts {
            let cur = totals[a.currency] ?? (0, 0)
            totals[a.currency] = (cur.sum + a.value, cur.count + 1)
        }
        let parts = totals.sorted { $0.key < $1.key }.map { cur, t in
            "\(cur) \(format(t.sum)) (×\(t.count))"
        }
        return "Found \(amounts.count) monetary amount(s): " + parts.joined(separator: ", ") + "."
    }

    static func parse(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }

    static func code(forSymbol s: String) -> String {
        switch s {
        case "$": return "USD"
        case "€": return "EUR"
        case "£": return "GBP"
        case "¥": return "JPY"
        default: return s
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
