import Foundation

/// Turns a 0…1 model-confidence score (from DeepSeek's `logprobs`, via `TokenConfidence`) into a
/// human band + advice for the `confidence_check` tool. A low average token probability means the
/// model hesitated — worth verifying. Pure + deterministic → unit-testable.
enum ConfidenceBand {
    /// (band, advice) for a confidence in 0…1 (clamped). Thresholds: ≥0.85 high, ≥0.6 moderate.
    static func describe(_ p: Double) -> (band: String, advice: String) {
        switch max(0, min(1, p)) {
        case 0.85...:
            return ("high", "well-supported by the model's token probabilities")
        case 0.6..<0.85:
            return ("moderate", "mostly confident — verify any specific facts")
        default:
            return ("low", "the model hesitated here — double-check this answer")
        }
    }

    /// Confidence as a whole-number percent (clamped to 0…100).
    static func percent(_ p: Double) -> Int { Int((max(0, min(1, p)) * 100).rounded()) }
}
