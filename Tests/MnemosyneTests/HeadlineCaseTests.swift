import XCTest
@testable import Mnemosyne

final class HeadlineCaseTests: XCTestCase {

    func testKeepsMinorWordsLowercaseExceptFirstLast() {
        XCTAssertEqual(HeadlineCase.titleize("the lord of the rings"), "The Lord of the Rings")
        XCTAssertEqual(HeadlineCase.titleize("a tale of two cities"), "A Tale of Two Cities")
        XCTAssertEqual(HeadlineCase.titleize("war and peace"), "War and Peace")
    }

    func testLastWordAlwaysCapitalized() {
        XCTAssertEqual(HeadlineCase.titleize("what are you waiting for"), "What Are You Waiting For")
    }

    func testNormalizesExistingCaseAndCollapsesSpaces() {
        XCTAssertEqual(HeadlineCase.titleize("THE QUICK   brown FOX"), "The Quick Brown Fox")
    }

    func testEmptyAndSingleWord() {
        XCTAssertEqual(HeadlineCase.titleize(""), "")
        XCTAssertEqual(HeadlineCase.titleize("of"), "Of")   // single word → capitalized even if minor
    }
}
