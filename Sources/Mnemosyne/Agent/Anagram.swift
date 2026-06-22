import Foundation

/// Anagram check for the `anagram` tool — do two phrases use exactly the same letters? Case,
/// spaces, and punctuation are ignored; only letters and digits count. Pure + deterministic →
/// unit-testable.
enum Anagram {
    /// Sorted lowercase letter/digit signature of a string — two strings are anagrams iff their
    /// signatures are equal.
    static func signature(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber }.sorted())
    }

    /// True when both phrases share the same multiset of letters/digits. Two empty (or
    /// punctuation-only) inputs are NOT considered anagrams — there's nothing to compare.
    static func isAnagram(_ a: String, _ b: String) -> Bool {
        let sa = signature(a)
        guard !sa.isEmpty else { return false }
        return sa == signature(b)
    }
}
