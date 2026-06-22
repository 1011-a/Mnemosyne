import Foundation

/// Encodes/decodes International Morse code for the `morse` tool. Letters and digits map to
/// dot/dash sequences; on encode, letters are separated by a space and words by " / ". Decode
/// is the inverse. Pure + deterministic → unit-testable. Pairs with `NatoPhonetic`.
enum MorseCode {
    private static let toMorse: [Character: String] = [
        "a": ".-", "b": "-...", "c": "-.-.", "d": "-..", "e": ".", "f": "..-.",
        "g": "--.", "h": "....", "i": "..", "j": ".---", "k": "-.-", "l": ".-..",
        "m": "--", "n": "-.", "o": "---", "p": ".--.", "q": "--.-", "r": ".-.",
        "s": "...", "t": "-", "u": "..-", "v": "...-", "w": ".--", "x": "-..-",
        "y": "-.--", "z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.", "!": "-.-.--",
        "/": "-..-.", "(": "-.--.", ")": "-.--.-", "&": ".-...", ":": "---...",
        ";": "-.-.-.", "=": "-...-", "+": ".-.-.", "-": "-....-", "_": "..--.-",
        "\"": ".-..-.", "@": ".--.-."
    ]
    private static let fromMorse: [String: Character] = {
        var m: [String: Character] = [:]
        for (k, v) in toMorse { m[v] = k }
        return m
    }()

    /// Text → Morse. Unknown characters are skipped. Returns nil for empty input or when nothing
    /// encodable is found.
    static func encode(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let words = text.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        var encWords: [String] = []
        for word in words {
            let codes = word.compactMap { toMorse[$0] }
            if !codes.isEmpty { encWords.append(codes.joined(separator: " ")) }
        }
        return encWords.isEmpty ? nil : encWords.joined(separator: " / ")
    }

    /// Morse → text (uppercase). Words split on "/", letters on whitespace. Unknown symbols
    /// become "?". Returns nil for empty input.
    static func decode(_ morse: String) -> String? {
        let trimmed = morse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = trimmed.components(separatedBy: "/")
        var out: [String] = []
        for word in words {
            let letters = word.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            guard !letters.isEmpty else { continue }
            let decoded = letters.map { fromMorse[String($0)].map(String.init) ?? "?" }.joined()
            out.append(decoded)
        }
        return out.isEmpty ? nil : out.joined(separator: " ").uppercased()
    }
}
