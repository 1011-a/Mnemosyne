import XCTest
@testable import Mnemosyne

final class WordFrequencyTests: XCTestCase {

    func testCountsContentWordsFilteringStopAndShortWords() {
        // "the" (stopword) and "on" (length 2) are dropped; "cat" recurs.
        let top = WordFrequency.top("the cat sat on the mat the cat")
        let dict = Dictionary(top.map { ($0.word, $0.count) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["cat"], 2)
        XCTAssertEqual(dict["mat"], 1)
        XCTAssertNil(dict["the"])
        XCTAssertNil(dict["on"])
    }

    func testRanksByFrequencyThenAlpha() {
        let top = WordFrequency.top("delta alpha alpha beta beta")
        XCTAssertEqual(top.first?.word, "alpha")        // tie at 2 → alpha before beta
        XCTAssertEqual(top.first?.count, 2)
    }

    func testTopCap() {
        XCTAssertEqual(WordFrequency.top("apple banana cherry date", n: 2).count, 2)
    }

    func testSummaryFormatAndEmptyIsNil() {
        let s = WordFrequency.summary("report report budget")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("report (2)"), s ?? "")
        XCTAssertNil(WordFrequency.summary("the on at a an"))   // all stop/short → nil
    }
}
