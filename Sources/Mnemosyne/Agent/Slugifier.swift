import Foundation

/// Turns a string into a URL/filename-safe SLUG for the `slugify` tool — title → anchor or
/// export filename ("My Great Note!" → "my-great-note"). Folds accents to ASCII, lowercases,
/// and collapses any run of non-alphanumerics into a single hyphen. Pure + deterministic →
/// unit-testable.
enum Slugifier {
    static func slugify(_ s: String, maxLength: Int = 80) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
        var slug = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        slug = trimHyphens(slug)
        if slug.count > maxLength {
            slug = trimHyphens(String(slug.prefix(maxLength)))
        }
        return slug
    }

    private static func trimHyphens(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
