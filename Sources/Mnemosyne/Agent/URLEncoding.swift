import Foundation

/// Percent-encodes/decodes text for URLs for the `url_encode` tool — build or read query
/// strings ('hello world' ↔ 'hello%20world'). Encoding uses the RFC-3986 unreserved set, so
/// reserved characters like & = ? / # space are all escaped. Pure + deterministic →
/// unit-testable.
enum URLEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Decode percent-encoding; nil if the input has malformed escapes.
    static func decode(_ s: String) -> String? {
        s.removingPercentEncoding
    }
}
