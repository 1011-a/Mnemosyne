import XCTest
@testable import Mnemosyne

/// NLTagger sentiment is model-driven, so these assert the SIGN/label (robust) on
/// unambiguous text rather than exact scores.
final class SentimentAnalyzerTests: XCTestCase {

    func testPositiveTextScoresPositive() {
        let s = SentimentAnalyzer.score("I love this. It is wonderful, delightful, and the best day ever!")
        XCTAssertNotNil(s)
        XCTAssertGreaterThan(s!, 0, "clearly positive text should score > 0 (got \(s!))")
    }

    func testNegativeTextScoresNegative() {
        let s = SentimentAnalyzer.score("This is terrible. I hate it — awful, miserable, the worst experience.")
        XCTAssertNotNil(s)
        XCTAssertLessThan(s!, 0, "clearly negative text should score < 0 (got \(s!))")
    }

    func testLabelBoundaries() {
        XCTAssertEqual(SentimentAnalyzer.label(0.9), "very positive")
        XCTAssertEqual(SentimentAnalyzer.label(0.3), "positive")
        XCTAssertEqual(SentimentAnalyzer.label(0.0), "neutral")
        XCTAssertEqual(SentimentAnalyzer.label(-0.3), "negative")
        XCTAssertEqual(SentimentAnalyzer.label(-0.9), "very negative")
    }

    func testSummaryAndEmpty() {
        XCTAssertNil(SentimentAnalyzer.score(""))
        XCTAssertNil(SentimentAnalyzer.summary("   \n  "))
        let summary = SentimentAnalyzer.summary("Fantastic, I am so happy with the result!")
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("score"), "summary: \(summary ?? "")")
    }
}
