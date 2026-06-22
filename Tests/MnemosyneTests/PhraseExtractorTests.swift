import XCTest
@testable import Mnemosyne

final class PhraseExtractorTests: XCTestCase {

    func testFindsRecurringBigrams() {
        let text = """
        Machine learning is great. Machine learning helps everyone.
        The quarterly report is due. Quarterly report review tomorrow.
        """
        let phrases = PhraseExtractor.extract(text)
        let dict = Dictionary(uniqueKeysWithValues: phrases.map { ($0.phrase, $0.count) })
        XCTAssertEqual(dict["machine learning"], 2)
        XCTAssertEqual(dict["quarterly report"], 2)
    }

    func testExcludesStopwordAndShortTokenGrams() {
        // "of the", "is due" etc. contain stopwords/short tokens → never a phrase.
        let phrases = PhraseExtractor.extract("part of the team. part of the team again.")
        XCTAssertFalse(phrases.contains { $0.phrase.contains("of") || $0.phrase.contains("the") }, "\(phrases)")
    }

    func testSingleOccurrencePhrasesDroppedAndEmptyIsNil() {
        // Each bigram appears once → nothing recurs → nil.
        XCTAssertNil(PhraseExtractor.summary("alpha beta gamma delta epsilon zeta"))
        XCTAssertNil(PhraseExtractor.summary(""))
    }

    func testSummaryFormat() {
        let s = PhraseExtractor.summary("neural network design. neural network tuning.")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("neural network (2)"), s ?? "")
        XCTAssertTrue(s!.hasPrefix("Key phrases:"), s ?? "")
    }
}
