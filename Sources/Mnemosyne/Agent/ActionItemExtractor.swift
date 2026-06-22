import Foundation

/// Pulls actionable TASKS / TODOs / commitments out of a document's text for the
/// `extract_action_items` tool — so the agent can turn ingested notes into follow-ups
/// (and optionally reminders). Recognizes three forms, in priority order:
///   1. Markdown unchecked checkboxes   `- [ ] ship the report`   (checked `[x]` skipped)
///   2. Explicit markers                `TODO: call Sam`, `FIXME - retry`, `ACTION: sign`
///   3. Commitment phrasing             "I need to …", "we must …", "remember to …",
///                                      "follow up on …", "don't forget to …"
/// Pure + deterministic → unit-testable. Returns distinct items in document order, each
/// trimmed of bullets/markers and surrounding punctuation.
enum ActionItemExtractor {

    /// Phrases that mark a line as a commitment / required action.
    private static let commitment =
        #"(?i)\b(?:need(?:s)? to|have to|has to|must|should|ought to|remember to|don'?t forget to|follow[ -]?up(?: on)?|action required|to[ -]?do)\b"#

    static func extract(_ text: String, max: Int = 50) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func push(_ raw: String) {
            let item = clean(raw)
            guard item.count >= 3 else { return }
            if seen.insert(item.lowercased()).inserted { out.append(item) }
        }

        // Pre-compile the line matchers.
        let checkbox = try? NSRegularExpression(pattern: #"^\s*[-*+]?\s*\[\s\]\s*(.+?)\s*$"#)
        let marker   = try? NSRegularExpression(pattern: #"(?i)\b(?:TODO|FIXME|ACTION(?: ITEM)?)\b\s*[:\-–]?\s*(.+?)\s*$"#)
        let commit   = try? NSRegularExpression(pattern: commitment)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)

            // Skip already-completed checkbox items entirely.
            if line.range(of: #"^\s*[-*+]?\s*\[[xX]\]"#, options: .regularExpression) != nil { continue }

            if let m = checkbox?.firstMatch(in: line, range: whole), m.numberOfRanges > 1 {
                push(ns.substring(with: m.range(at: 1))); if out.count >= max { break }; continue
            }
            if let m = marker?.firstMatch(in: line, range: whole), m.numberOfRanges > 1 {
                push(ns.substring(with: m.range(at: 1))); if out.count >= max { break }; continue
            }
            if commit?.firstMatch(in: line, range: whole) != nil {
                push(line); if out.count >= max { break }; continue
            }
        }
        return out
    }

    /// Strip leading bullets/numbering and surrounding noise from a captured item.
    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        // Leading list markers: "- ", "* ", "1. ", "1) ", "• "
        if let r = t.range(of: #"^(?:[-*+•]|\d+[.)])\s+"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—•*")).trimmingCharacters(in: .whitespaces)
    }
}
