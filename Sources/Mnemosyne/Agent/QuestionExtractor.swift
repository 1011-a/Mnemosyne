import Foundation
import NaturalLanguage

/// Pulls the QUESTIONS out of a document for the `extract_questions` tool — for turning a
/// doc into an FAQ, study deck, or interview prep ("what questions does this raise?").
/// Sentence-segments with Apple's native `NLTokenizer` (multilingual), then keeps the
/// sentences that end with a question mark (ASCII `?` or full-width `？`). Pure +
/// deterministic → unit-testable. Distinct, in document order.
enum QuestionExtractor {
    static func extract(_ text: String, max: Int = 50) -> [String] {
        guard !text.isEmpty else { return [] }
        let tk = NLTokenizer(unit: .sentence)
        tk.string = text
        var out: [String] = []
        var seen = Set<String>()
        tk.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (s.hasSuffix("?") || s.hasSuffix("？")), s.count >= 3,
               seen.insert(s.lowercased()).inserted {
                out.append(s)
                if out.count >= max { return false }
            }
            return true
        }
        return out
    }
}
