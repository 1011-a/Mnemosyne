import Foundation

/// Spells text using the NATO phonetic alphabet for the `nato` tool — read out codes, names, or
/// confirmation numbers unambiguously over the phone. Letters → Alfa/Bravo/…, digits → their
/// ICAO words, space → "(space)". Pure + deterministic → unit-testable.
enum NatoPhonetic {
    private static let letters: [Character: String] = [
        "a": "Alfa", "b": "Bravo", "c": "Charlie", "d": "Delta", "e": "Echo",
        "f": "Foxtrot", "g": "Golf", "h": "Hotel", "i": "India", "j": "Juliett",
        "k": "Kilo", "l": "Lima", "m": "Mike", "n": "November", "o": "Oscar",
        "p": "Papa", "q": "Quebec", "r": "Romeo", "s": "Sierra", "t": "Tango",
        "u": "Uniform", "v": "Victor", "w": "Whiskey", "x": "Xray", "y": "Yankee", "z": "Zulu"
    ]
    private static let digits: [Character: String] = [
        "0": "Zero", "1": "One", "2": "Two", "3": "Three", "4": "Four",
        "5": "Five", "6": "Six", "7": "Seven", "8": "Eight", "9": "Nine"
    ]

    /// Each recognized character becomes its code word; unknown punctuation is passed through
    /// verbatim. Returns nil for empty input.
    static func spell(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var out: [String] = []
        for ch in text {
            if ch == " " {
                out.append("(space)")
            } else if let word = letters[Character(ch.lowercased())] {
                out.append(word)
            } else if let word = digits[ch] {
                out.append(word)
            } else {
                out.append(String(ch))
            }
        }
        return out.joined(separator: " ")
    }
}
