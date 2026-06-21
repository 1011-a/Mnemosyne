import Foundation

/// Pulls human-readable DATES out of a document's text for the `extract_dates` tool
/// (deadlines, events, "what dates are in this file"). Recognizes ISO (2026-01-05),
/// slashed (5/1/2026), and month-name forms ("Jan 5, 2026" / "5 January 2026"). Pure
/// + deterministic → unit-testable. Returns distinct matches in document order.
enum DateExtractor {
    private static let months =
        "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

    static func extract(_ text: String, max: Int = 50) -> [String] {
        let patterns = [
            #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,                                              // 2026-01-05
            #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,                                            // 5/1/2026
            "(?i)\\b(?:\(months))\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4}\\b",      // Jan 5, 2026
            "(?i)\\b\\d{1,2}(?:st|nd|rd|th)?\\s+(?:\(months))\\.?,?\\s+\\d{4}\\b",      // 5 January 2026
        ]
        let ns = text as NSString
        var hits: [(loc: Int, value: String)] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                hits.append((m.range.location, ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)))
            }
        }
        hits.sort { $0.loc < $1.loc }
        var out: [String] = []
        var seen = Set<String>()
        for h in hits where seen.insert(h.value.lowercased()).inserted {
            out.append(h.value)
            if out.count >= max { break }
        }
        return out
    }
}
