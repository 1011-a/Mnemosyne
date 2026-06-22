import Foundation

/// Pulls TIMES OF DAY out of a document for the `extract_times` tool — schedules and meeting
/// notes ("3:30 PM", "09:00", "12pm"). Hour/minute ranges are validated in the pattern, so
/// "25:99" won't match. Distinct from `extract_dates`. Pure + deterministic → unit-testable.
enum TimeExtractor {
    private static let patterns = [
        #"\b([01]?\d|2[0-3]):([0-5]\d)(\s*[AaPp][Mm])?\b"#,   // HH:MM with optional am/pm
        #"\b(1[0-2]|0?[1-9])\s*[AaPp][Mm]\b"#,                 // bare hour + am/pm (e.g. 12pm)
    ]

    static func extract(_ text: String, max: Int = 100) -> [String] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [String] = []
        var seen = Set<String>()
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let t = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                let key = t.lowercased().replacingOccurrences(of: " ", with: "")
                if seen.insert(key).inserted {
                    out.append(t)
                    if out.count >= max { return out }
                }
            }
        }
        return out
    }

    static func summary(_ text: String, max: Int = 100) -> String? {
        let times = extract(text, max: max)
        guard !times.isEmpty else { return nil }
        return "\(times.count) time(s): " + times.joined(separator: ", ")
    }
}
