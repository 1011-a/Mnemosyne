import Foundation
import NaturalLanguage

/// On-device LANGUAGE detection for the `detect_language` tool — answers "what language
/// is this file in?" and lets the agent decide whether to translate. Uses Apple's native
/// `NLLanguageRecognizer` (zero-dependency, offline, private; same NaturalLanguage family
/// as the embedder, entity extractor, and sentiment analyzer). Deterministic for a given
/// input → unit-testable.
enum LanguageDetector {

    struct Result: Sendable {
        let dominant: String                              // BCP-47 code, e.g. "en", "zh-Hans"
        let dominantName: String                          // localized name, e.g. "English"
        let hypotheses: [(code: String, confidence: Double)]   // ranked, most-confident first
    }

    static func detect(_ text: String, maxHypotheses: Int = 3) -> Result? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: maxHypotheses)
            .map { (code: $0.key.rawValue, confidence: $0.value) }
            .sorted { $0.confidence > $1.confidence }
        return Result(dominant: dominant.rawValue, dominantName: name(for: dominant.rawValue),
                      hypotheses: hypotheses)
    }

    /// The English display name for a BCP-47 language code ("en" → "English").
    static func name(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// A one-line tool reply, e.g. "English (en, 99%)  ·  also: French (12%)".
    static func summary(_ text: String) -> String? {
        guard let r = detect(text) else { return nil }
        func pct(_ c: Double) -> String { "\(Int((c * 100).rounded()))%" }
        var line = "\(r.dominantName) (\(r.dominant)"
        if let top = r.hypotheses.first(where: { $0.code == r.dominant }) { line += ", \(pct(top.confidence))" }
        line += ")"
        let others = r.hypotheses
            .filter { $0.code != r.dominant && $0.confidence >= 0.05 }
            .map { "\(name(for: $0.code)) (\(pct($0.confidence)))" }
        if !others.isEmpty { line += "  ·  also: " + others.joined(separator: ", ") }
        return line
    }
}
