import XCTest
@testable import Mnemosyne

final class TruncateTests: XCTestCase {

    func testCharTruncation() {
        XCTAssertEqual(Truncate.toChars("hello world", 5), "hello…")
        XCTAssertEqual(Truncate.toChars("hi", 5), "hi")          // shorter than max → unchanged
        XCTAssertEqual(Truncate.toChars("ab cd", 3), "ab…")      // trailing space trimmed before ellipsis
    }

    func testWordTruncation() {
        XCTAssertEqual(Truncate.toWords("the quick brown fox", 2), "the quick…")
        XCTAssertEqual(Truncate.toWords("a b", 5), "a b")        // fewer words than max → unchanged
    }

    func testZeroOrNegativeMaxReturnsOriginal() {
        XCTAssertEqual(Truncate.toChars("hello", 0), "hello")
        XCTAssertEqual(Truncate.toWords("a b c", -1), "a b c")
    }
}
