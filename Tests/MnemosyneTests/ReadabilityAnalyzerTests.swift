import XCTest
@testable import Mnemosyne

final class ReadabilityAnalyzerTests: XCTestCase {

    func testSyllableHeuristic() {
        XCTAssertEqual(ReadabilityAnalyzer.syllables(in: "cat"), 1)
        XCTAssertEqual(ReadabilityAnalyzer.syllables(in: "apple"), 2)   // a + le ending kept
        XCTAssertEqual(ReadabilityAnalyzer.syllables(in: "make"), 1)    // silent trailing e
        XCTAssertEqual(ReadabilityAnalyzer.syllables(in: "the"), 1)     // short word: e not stripped
        // Vowel-group heuristic approximates: "readability" counts 5 groups (ea,a,i,i,y).
        XCTAssertEqual(ReadabilityAnalyzer.syllables(in: "readability"), 5)
        XCTAssertEqual(ReadabilityAnalyzer.syllables(in: "123"), 0, "no letters ⇒ no syllables")
    }

    func testFleschFormulaAndBounds() {
        // Short, simple sentence scores high (easy).
        let easy = ReadabilityAnalyzer.fleschReadingEase(words: 6, sentences: 1, syllables: 7)
        XCTAssertNotNil(easy)
        XCTAssertGreaterThan(easy!, 70, "short words, short sentence ⇒ easy (got \(easy!))")

        // Long sentence of polysyllabic words scores low (hard), clamped ≥ 0.
        let hard = ReadabilityAnalyzer.fleschReadingEase(words: 40, sentences: 1, syllables: 120)
        XCTAssertNotNil(hard)
        XCTAssertLessThan(hard!, 30, "dense ⇒ hard (got \(hard!))")
        XCTAssertGreaterThanOrEqual(hard!, 0, "clamped to 0")

        // Degenerate inputs return nil rather than dividing by zero.
        XCTAssertNil(ReadabilityAnalyzer.fleschReadingEase(words: 0, sentences: 1, syllables: 1))
        XCTAssertNil(ReadabilityAnalyzer.fleschReadingEase(words: 5, sentences: 0, syllables: 5))
    }

    func testGradeBands() {
        XCTAssertEqual(ReadabilityAnalyzer.grade(95), "very easy (5th grade)")
        XCTAssertEqual(ReadabilityAnalyzer.grade(60), "plain (8th–10th grade)")
        XCTAssertEqual(ReadabilityAnalyzer.grade(10), "very hard (graduate / technical)")
    }

    func testAnalyzeEnglishAndGuards() {
        let easy = ReadabilityAnalyzer.analyze("The cat sat on the mat. The dog ran in the sun. We had fun.")
        XCTAssertNotNil(easy)
        XCTAssertGreaterThan(easy!.score, 70, "plain English scores easy (got \(easy?.score ?? -1))")
        XCTAssertGreaterThanOrEqual(easy!.sentences, 2)

        // Too short ⇒ nil.
        XCTAssertNil(ReadabilityAnalyzer.analyze("Hi."))
        // Non-Latin (Chinese) ⇒ nil (the English syllable model doesn't apply).
        XCTAssertNil(ReadabilityAnalyzer.analyze("这是一段中文文字，用来测试可读性评分应当被跳过，因为它不是拉丁文字。"))

        // Summary mirrors the guard.
        XCTAssertNotNil(ReadabilityAnalyzer.summary("This is a perfectly ordinary English sentence for scoring."))
        XCTAssertNil(ReadabilityAnalyzer.summary(""))
    }
}
