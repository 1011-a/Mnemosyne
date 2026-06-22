import Foundation

/// Derives a confidence signal from DeepSeek's `logprobs` — the per-token log-probabilities the
/// API returns when `logprobs: true` is set. A high average token probability means the model was
/// "sure"; a low one (or a few very-low tokens) flags a shaky answer worth double-checking. Pure +
/// deterministic → unit-testable. Used by `DeepSeekClient.answerWithConfidence`.
enum TokenConfidence {
    struct Token: Equatable { let token: String; let logprob: Double }

    /// Extract the chosen-token logprobs from a chat-completions response. nil when the body has
    /// no `logprobs.content` (e.g. logprobs weren't requested) or doesn't decode.
    static func parse(from data: Data) -> [Token]? {
        struct Wire: Decodable {
            struct Choice: Decodable {
                struct LP: Decodable {
                    struct Tok: Decodable { let token: String; let logprob: Double }
                    let content: [Tok]?
                }
                let logprobs: LP?
            }
            let choices: [Choice]?
        }
        guard let content = (try? JSONDecoder().decode(Wire.self, from: data))?
            .choices?.first?.logprobs?.content else { return nil }
        return content.map { Token(token: $0.token, logprob: $0.logprob) }
    }

    /// Average token probability (0…1): the mean of exp(logprob) across tokens — an intuitive
    /// "how confident, on average" score. nil for an empty list.
    static func averageProbability(_ tokens: [Token]) -> Double? {
        guard !tokens.isEmpty else { return nil }
        let sum = tokens.reduce(0.0) { $0 + exp($1.logprob) }
        return sum / Double(tokens.count)
    }

    /// The `count` least-confident tokens (lowest probability first) with their 0…1 probabilities —
    /// useful for highlighting where the model hesitated.
    static func leastConfident(_ tokens: [Token], count: Int = 3) -> [(token: String, probability: Double)] {
        tokens.sorted { $0.logprob < $1.logprob }
            .prefix(max(0, count))
            .map { (token: $0.token, probability: exp($0.logprob)) }
    }
}
