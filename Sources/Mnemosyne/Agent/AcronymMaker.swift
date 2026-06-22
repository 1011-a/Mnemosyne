import Foundation

/// Makes an acronym from a phrase for the `acronym` tool — the first letter of each word,
/// uppercased ("Portable Document Format" → "PDF"). Optionally skips minor words (the, of, …).
/// Pure + deterministic → unit-testable.
enum AcronymMaker {
    private static let minor: Set<String> = ["a", "an", "the", "of", "and", "or", "for", "to", "in", "on"]

    static func make(_ phrase: String, skipMinor: Bool = false) -> String {
        var result = ""
        for word in phrase.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init) {
            if skipMinor, minor.contains(word.lowercased()) { continue }
            if let letter = word.first(where: { $0.isLetter }) {
                result.append(Character(letter.uppercased()))
            }
        }
        return result
    }
}
