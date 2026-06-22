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

    /// Parse one extracted date string (any of the recognized formats) into a `Date` for
    /// sorting. Slashed dates are read as M/D/Y (US style). Returns nil if unparseable.
    /// Pure → unit-testable.
    static func parse(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let formats = ["yyyy-MM-dd", "M/d/yyyy", "M/d/yy",
                       "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy", "d MMMM yyyy"]
        // Strip ordinal suffixes (1st, 2nd, 3rd, 4th) the formatters don't accept.
        let cleaned = trimmed.replacingOccurrences(
            of: #"(\d{1,2})(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    /// Extract the dates from `text` and order them CHRONOLOGICALLY (earliest first).
    /// Unparseable but recognized strings are appended in document order at the end.
    /// Backs the `timeline` tool. Pure → unit-testable.
    static func chronological(_ text: String, max: Int = 50) -> [String] {
        let found = extract(text, max: max)
        let dated = found.map { (raw: $0, date: parse($0)) }
        let parseable = dated.compactMap { p in p.date.map { (raw: p.raw, date: $0) } }
            .sorted { $0.date < $1.date }.map(\.raw)
        let unparseable = dated.filter { $0.date == nil }.map(\.raw)
        return parseable + unparseable
    }
}
