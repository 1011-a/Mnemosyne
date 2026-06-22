import XCTest
@testable import Mnemosyne

final class UnicodeInfoTests: XCTestCase {

    func testBasicLatin() {
        let g = UnicodeInfo.inspect("A")
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.codepoint, "U+0041")
        XCTAssertEqual(g.first?.name, "LATIN CAPITAL LETTER A")
    }

    func testMultipleCharsAndOrder() {
        let g = UnicodeInfo.inspect("ab")
        XCTAssertEqual(g.map(\.codepoint), ["U+0061", "U+0062"])
    }

    func testEmojiAndCJK() {
        XCTAssertEqual(UnicodeInfo.inspect("😀").first?.name, "GRINNING FACE")
        XCTAssertEqual(UnicodeInfo.inspect("好").first?.codepoint, "U+597D")
    }

    func testEmptyAndLimitAndTable() {
        XCTAssertTrue(UnicodeInfo.inspect("").isEmpty)
        XCTAssertEqual(UnicodeInfo.inspect("abcdef", limit: 2).count, 2)
        XCTAssertEqual(UnicodeInfo.table(UnicodeInfo.inspect("A")), "U+0041  A  LATIN CAPITAL LETTER A")
    }
}
