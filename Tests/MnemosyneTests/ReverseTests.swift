import XCTest
@testable import Mnemosyne

final class ReverseTests: XCTestCase {

    func testReverseChars() {
        XCTAssertEqual(Reverse.chars("hello"), "olleh")
        XCTAssertEqual(Reverse.chars("abc"), "cba")
    }

    func testReverseCharsGraphemeSafe() {
        XCTAssertEqual(Reverse.chars("café"), "éfac")   // é stays one character
    }

    func testReverseWords() {
        XCTAssertEqual(Reverse.words("the quick brown fox"), "fox brown quick the")
        XCTAssertEqual(Reverse.words("a  b   c"), "c b a")   // collapses whitespace
    }

    func testEmptyAndSingle() {
        XCTAssertEqual(Reverse.chars(""), "")
        XCTAssertEqual(Reverse.words("solo"), "solo")
    }
}
