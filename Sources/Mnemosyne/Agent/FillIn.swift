import Foundation

/// Cleans the output of DeepSeek's FIM (fill-in-the-middle) completion for the `fill_in` tool.
/// FIM returns just the generated middle, but models sometimes run past the gap and re-emit the
/// suffix; this trims that echo so the inserted text stitches cleanly between prefix and suffix.
/// Pure + deterministic → unit-testable. Pairs with [[DeepSeekFIM]].
enum FillIn {
    /// If `suffix` is non-empty and `generated` contains it, drop everything from the first
    /// occurrence onward (the model leaked into the suffix). Otherwise return `generated`
    /// unchanged. A trailing newline left by the cut is preserved (it's usually wanted between
    /// the inserted block and the suffix).
    static func trimSuffixEcho(_ generated: String, suffix: String) -> String {
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuffix.isEmpty, let r = generated.range(of: trimmedSuffix) else {
            return generated
        }
        return String(generated[..<r.lowerBound])
    }
}
