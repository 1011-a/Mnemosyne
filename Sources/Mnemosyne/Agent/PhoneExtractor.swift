import Foundation

/// Pulls PHONE NUMBERS out of a document for the `extract_phone_numbers` tool (collecting
/// contacts, alongside `extract_emails`). Recognizes international (+CC …), US area-code
/// parens ((415) 555-2671), and separated forms (415-555-2671 / 415.555.2671 / 415 555
/// 2671). Pure + deterministic → unit-testable. Distinct (by digit-only signature) and in
/// document order. Conservative shapes keep dates / IDs from matching.
enum PhoneExtractor {
    private static let patterns = [
        #"\+\d[\d\s().-]{7,16}\d"#,                       // +44 20 7946 0958 / +1 (415) 555-2671
        #"\(\d{3}\)\s?\d{3}[\s.-]?\d{4}"#,                // (415) 555-2671
        #"\b\d{3}[\s.-]\d{3}[\s.-]\d{4}\b"#,             // 415-555-2671 / 415.555.2671 / 415 555 2671
    ]

    static func extract(_ text: String, max: Int = 80) -> [String] {
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
        var seen = Set<String>()           // dedupe by digit-only signature (formatting-agnostic)
        for h in hits {
            let digits = h.value.filter(\.isNumber)
            guard digits.count >= 7, digits.count <= 15, seen.insert(digits).inserted else { continue }
            out.append(h.value)
            if out.count >= max { break }
        }
        return out
    }
}
