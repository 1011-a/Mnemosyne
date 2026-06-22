import XCTest
@testable import Mnemosyne

final class ExtractiveSummaryTests: XCTestCase {

    func testSentenceSplittingKeepsEllipsisTogether() {
        let s = ExtractiveSummary.sentences("First sentence. Second one! Wait... really?")
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[0], "First sentence.")
        XCTAssertEqual(s[2], "Wait...")
        XCTAssertEqual(s[3], "really?")
    }

    func testTokensDropStopwordsShortWordsAndPunctuation() {
        let t = ExtractiveSummary.tokens("The cats and dogs, run!")
        XCTAssertEqual(t, ["cats", "dogs", "run"])   // "the"/"and" stop, all letters-only
    }

    func testSummaryPicksSalientSentencesInOriginalOrder() {
        let text = "Cats are great pets. Cats purr and cats cuddle. The weather today is rainy. I might buy an umbrella."
        let summary = ExtractiveSummary.summarize(text, maxSentences: 2)
        XCTAssertNotNil(summary)
        // "cats" is the most frequent topic → the two cat sentences win, in document order.
        XCTAssertTrue(summary!.contains("Cats purr and cats cuddle."), summary ?? "")
        XCTAssertFalse(summary!.contains("umbrella"), "off-topic sentence excluded: \(summary ?? "")")
        // Original order preserved (S1 before S2).
        XCTAssertLessThan(summary!.range(of: "great pets")!.lowerBound,
                          summary!.range(of: "purr")!.lowerBound)
    }

    func testShortTextReturnedWholeAndEmptyIsNil() {
        XCTAssertEqual(ExtractiveSummary.summarize("Only one sentence here.", maxSentences: 3),
                       "Only one sentence here.")
        XCTAssertNil(ExtractiveSummary.summarize("   "))
    }
}
