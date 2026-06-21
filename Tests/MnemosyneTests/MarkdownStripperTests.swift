import XCTest
@testable import Mnemosyne

final class MarkdownStripperTests: XCTestCase {

    func testStripsInlineFormatting() {
        let out = MarkdownStripper.strip("Some **bold** and *italic* and `code` here.")
        XCTAssertEqual(out, "Some bold and italic and code here.")
    }

    func testStripsHeadingsBulletsAndQuotes() {
        let md = "# Title\n- item one\n> a quote\n1. first"
        let out = MarkdownStripper.strip(md)
        XCTAssertEqual(out, "Title\nitem one\na quote\nfirst")
    }

    func testLinksAndImagesReduceToText() {
        XCTAssertEqual(MarkdownStripper.strip("A [link](http://x.com) here."), "A link here.")
        XCTAssertEqual(MarkdownStripper.strip("![alt text](http://x.com/i.png)"), "alt text")
    }

    func testPreservesSnakeCaseAndRemovesNoMarkdownUnchanged() {
        XCTAssertEqual(MarkdownStripper.strip("the snake_case_var stays intact"),
                       "the snake_case_var stays intact")
        XCTAssertTrue(MarkdownStripper.strip("plain sentence").contains("plain sentence"))
    }
}
