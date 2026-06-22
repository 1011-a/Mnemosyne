import XCTest
@testable import Mnemosyne

final class QuoteExtractorTests: XCTestCase {

    func testExtractsStraightQuotes() {
        XCTAssertEqual(QuoteExtractor.extract("He said \"hello world\" today."), ["hello world"])
    }

    func testExtractsMultipleAndSmartQuotes() {
        XCTAssertEqual(QuoteExtractor.extract("x \"one\" y \"two\""), ["one", "two"])
        XCTAssertEqual(QuoteExtractor.extract("\u{201C}a smart quote\u{201D} and more"), ["a smart quote"])
    }

    func testDedupesAndSkipsTooShortAndUnclosed() {
        XCTAssertEqual(QuoteExtractor.extract("\"dup\" then \"dup\" again"), ["dup"])
        XCTAssertTrue(QuoteExtractor.extract("just \"a\" tiny one").isEmpty)   // single char < 2
        XCTAssertTrue(QuoteExtractor.extract("an \"unclosed quote here").isEmpty)
    }

    func testSummaryAndEmpty() {
        let s = QuoteExtractor.summary("She wrote \"be kind\".")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("1 quote(s)"), s ?? "")
        XCTAssertTrue(s!.contains("be kind"), s ?? "")
        XCTAssertNil(QuoteExtractor.summary("no quotes here"))
    }
}
