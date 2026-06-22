import Foundation

/// Counts characters/words/lines/sentences of provided text for the `count_text` tool — the
/// in-context counterpart to the item-based `text_stats`. Reuses `TextStats` for word/sentence
/// logic. Pure + deterministic → unit-testable.
enum TextCounts {
    struct Counts: Equatable {
        let characters: Int
        let charactersNoSpaces: Int
        let words: Int
        let lines: Int
        let sentences: Int
    }

    static func count(_ text: String) -> Counts {
        let chars = text.count
        let noSpaces = text.filter { !$0.isWhitespace }.count
        let words = TextStats.wordTokens(text).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        let sc = TextStats.sentenceCount(text)
        let sentences = (sc == 0 && words > 0) ? 1 : sc
        return Counts(characters: chars, charactersNoSpaces: noSpaces, words: words, lines: lines, sentences: sentences)
    }

    static func report(_ text: String) -> String {
        let c = count(text)
        return "Characters: \(c.characters) (\(c.charactersNoSpaces) excl. spaces), "
            + "Words: \(c.words), Lines: \(c.lines), Sentences: \(c.sentences)"
    }
}
