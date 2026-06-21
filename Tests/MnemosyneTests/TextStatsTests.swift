import XCTest
@testable import Mnemosyne

final class TextStatsTests: XCTestCase {

    func testWordAndSentenceCounts() {
        let s = TextStats.analyze("The cat sat. The dog ran!")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.words, 6)
        XCTAssertEqual(s?.sentences, 2)
    }

    func testEllipsisCountsAsOneSentence() {
        XCTAssertEqual(TextStats.sentenceCount("Wait... really?!"), 2)  // "..." → 1, "?!" → 1
        XCTAssertEqual(TextStats.sentenceCount("no terminator here"), 0)
    }

    func testSyllableHeuristicIncludingSilentEAndLe() {
        XCTAssertEqual(TextStats.syllables("cat"), 1)
        XCTAssertEqual(TextStats.syllables("hello"), 2)
        XCTAssertEqual(TextStats.syllables("make"), 1)    // silent trailing e dropped
        XCTAssertEqual(TextStats.syllables("table"), 2)   // "le" ending NOT dropped
        XCTAssertEqual(TextStats.syllables("a"), 1)       // floor of 1
    }

    func testReadingEaseBandAndReport() {
        // Short, simple words → high reading ease.
        XCTAssertEqual(TextStats.readingEaseBand(95), "very easy")
        XCTAssertEqual(TextStats.readingEaseBand(65), "standard")
        XCTAssertEqual(TextStats.readingEaseBand(10), "very difficult")

        let report = TextStats.report("The cat sat on the mat. The dog ran fast.")
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.contains("words"), report ?? "")
        XCTAssertTrue(report!.contains("Reading ease"), report ?? "")
        XCTAssertNil(TextStats.analyze("   "), "whitespace-only → nil")
    }
}
