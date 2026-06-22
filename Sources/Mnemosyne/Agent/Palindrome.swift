import Foundation

/// Palindrome check for the `palindrome` tool — does the text read the same forwards and
/// backwards, ignoring case and non-alphanumerics? Pure + deterministic → unit-testable.
enum Palindrome {
    static func isPalindrome(_ text: String) -> Bool {
        let cleaned = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return false }
        return cleaned == String(cleaned.reversed())
    }
}
