import Foundation

/// Converts text between letter cases for the `change_case` tool — UPPER, lower, Title Case,
/// or Sentence case (cleanup, headings, normalizing pasted text). Pure + deterministic →
/// unit-testable.
enum CaseConverter {
    /// Returns the converted text, or nil for an unrecognized mode.
    static func convert(_ text: String, mode: String) -> String? {
        switch mode.lowercased() {
        case "upper", "uppercase": return text.uppercased()
        case "lower", "lowercase": return text.lowercased()
        case "title": return text.capitalized
        case "sentence": return sentenceCase(text)
        default: return nil
        }
    }

    /// Lowercase everything, then capitalize the first letter of each sentence.
    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" { capitalizeNext = true }
            }
        }
        return result
    }
}
