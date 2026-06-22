import Foundation

/// Validates a single email-address string for the `validate_email` tool — a pragmatic format
/// check (local@domain.tld), anchored so the whole string must match. Distinct from
/// `extract_emails` (which finds addresses in text). Pure + deterministic → unit-testable.
enum EmailValidator {
    private static let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#

    static func isValid(_ email: String) -> Bool {
        let s = email.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
