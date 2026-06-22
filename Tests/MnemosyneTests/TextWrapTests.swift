import XCTest
@testable import Mnemosyne

final class TextWrapTests: XCTestCase {

    func testWrapsAtWordBoundaries() {
        XCTAssertEqual(TextWrap.wrap("the quick brown fox jumps", width: 10),
                       "the quick\nbrown fox\njumps")
    }

    func testLongWordStaysWhole() {
        XCTAssertEqual(TextWrap.wrap("a superlongword b", width: 5),
                       "a\nsuperlongword\nb")
    }

    func testPreservesParagraphBreaks() {
        let out = TextWrap.wrap("one two three\n\nfour five six", width: 8)
        XCTAssertTrue(out.contains("\n\n"), out)            // blank line between paragraphs kept
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 2)
    }

    func testCollapsesWhitespaceWithinParagraph() {
        XCTAssertEqual(TextWrap.wrap("a    b\tc", width: 80), "a b c")
    }
}
