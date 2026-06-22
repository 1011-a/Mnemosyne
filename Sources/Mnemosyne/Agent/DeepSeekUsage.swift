import Foundation

/// Parses DeepSeek's `usage` block — including its native context-caching counters
/// (`prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`) that the OpenAI-shaped schema doesn't
/// model — out of a chat-completions response body. Cache hits are billed at a fraction of the
/// miss price, so surfacing the hit rate shows real cost/latency savings. Pure + deterministic →
/// unit-testable. Companion to [[DeepSeekReasoning]].
enum DeepSeekUsage {
    struct Usage: Equatable {
        let promptTokens: Int
        let completionTokens: Int
        let cacheHitTokens: Int
        let cacheMissTokens: Int

        /// Fraction (0…1) of prompt tokens served from cache, or nil when there were no prompt
        /// tokens or the cache counters are absent (sum is 0).
        var cacheHitRate: Double? {
            let total = cacheHitTokens + cacheMissTokens
            guard total > 0 else { return nil }
            return Double(cacheHitTokens) / Double(total)
        }
    }

    private struct Wire: Decodable {
        struct U: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cacheHit: Int?
            let cacheMiss: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case cacheHit = "prompt_cache_hit_tokens"
                case cacheMiss = "prompt_cache_miss_tokens"
            }
        }
        let usage: U?
    }

    /// Decode the usage block. nil when the body has no `usage` object or isn't decodable.
    static func parse(from data: Data) -> Usage? {
        guard let u = (try? JSONDecoder().decode(Wire.self, from: data))?.usage else { return nil }
        return Usage(promptTokens: u.promptTokens ?? 0,
                     completionTokens: u.completionTokens ?? 0,
                     cacheHitTokens: u.cacheHit ?? 0,
                     cacheMissTokens: u.cacheMiss ?? 0)
    }

    /// A one-line trace note like "Cache: 1,920/2,048 prompt tokens hit (94%)", or nil when there
    /// were no cached prompt tokens to report.
    static func cacheNote(_ usage: Usage) -> String? {
        guard let rate = usage.cacheHitRate, usage.cacheHitTokens > 0 else { return nil }
        let total = usage.cacheHitTokens + usage.cacheMissTokens
        let pct = Int((rate * 100).rounded())
        return "Cache: \(grouped(usage.cacheHitTokens))/\(grouped(total)) prompt tokens hit (\(pct)%)"
    }

    /// Thousands-separated integer (locale-independent) for the note.
    private static func grouped(_ n: Int) -> String {
        let s = String(n)
        guard n >= 1000 else { return s }
        var out = "", count = 0
        for ch in s.reversed() {
            if count != 0 && count % 3 == 0 { out.append(",") }
            out.append(ch); count += 1
        }
        return String(out.reversed())
    }
}
