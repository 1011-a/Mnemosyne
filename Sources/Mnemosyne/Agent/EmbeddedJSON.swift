import Foundation

/// Pulls valid JSON object(s)/array(s) embedded in a larger text for the `extract_json` tool
/// — JSON buried in model output, logs, or prose. Uses a string-aware balanced-bracket scan,
/// validating each candidate with JSONSerialization. Returns the original substrings (key
/// order preserved). Pure + deterministic → unit-testable.
enum EmbeddedJSON {
    static func candidates(_ text: String, max: Int = 20) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "[", let end = matchEnd(chars, start: i) {
                let candidate = String(chars[i...end])
                if isValidJSON(candidate) {
                    results.append(candidate)
                    if results.count >= max { break }
                    i = end + 1
                    continue
                }
            }
            i += 1
        }
        return results
    }

    static func first(_ text: String) -> String? {
        candidates(text, max: 1).first
    }

    /// Index of the bracket that closes the one at `start`, honoring strings/escapes; nil if none.
    private static func matchEnd(_ chars: [Character], start: Int) -> Int? {
        let open = chars[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func isValidJSON(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
