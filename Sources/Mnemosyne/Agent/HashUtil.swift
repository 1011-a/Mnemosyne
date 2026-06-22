import Foundation
import CryptoKit

/// Computes a content fingerprint for the `hash_text` tool — SHA-256 of text, for dedup,
/// checksums, or "are these two notes identical?". Pure + deterministic → unit-testable
/// against the standard SHA-256 test vectors.
enum HashUtil {
    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text`.
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A short fingerprint — the first 8 hex characters of the SHA-256.
    static func short(_ text: String) -> String {
        String(sha256(text).prefix(8))
    }
}
