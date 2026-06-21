import Foundation

/// Formats a one-call CONTACTS roll-up for the `extract_contacts` tool — combining the
/// people, emails, and phone numbers found in a document into a single structured answer
/// ("who do I contact in this file"). Pure → unit-testable; the extraction itself is done
/// by the existing EntityExtractor / EmailAddressExtractor / PhoneExtractor.
enum ContactRollup {

    /// Group the found pieces into "People / Emails / Phones" lines, deduping each list
    /// case-insensitively (preserving first spelling / order). Returns nil when nothing
    /// was found at all, so the caller can report cleanly.
    static func format(people: [String], emails: [String], phones: [String]) -> String? {
        func dedupe(_ xs: [String]) -> [String] {
            var seen = Set<String>(); var out: [String] = []
            for x in xs {
                let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
            }
            return out
        }
        let p = dedupe(people), e = dedupe(emails), ph = dedupe(phones)
        guard !p.isEmpty || !e.isEmpty || !ph.isEmpty else { return nil }
        var lines: [String] = []
        if !p.isEmpty  { lines.append("People: " + p.joined(separator: ", ")) }
        if !e.isEmpty  { lines.append("Emails: " + e.joined(separator: ", ")) }
        if !ph.isEmpty { lines.append("Phones: " + ph.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
