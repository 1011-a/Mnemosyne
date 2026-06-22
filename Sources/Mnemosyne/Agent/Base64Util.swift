import Foundation

/// Base64 encode/decode for the `base64` tool — handle encoded data the agent meets in notes
/// (data URIs, tokens, snippets). Pure + deterministic → unit-testable.
enum Base64Util {
    static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Decode base64 to text. Tolerant of embedded whitespace/newlines; nil when the input
    /// isn't valid base64 or the bytes aren't valid UTF-8.
    static func decode(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
