import XCTest
@testable import Mnemosyne

final class TextIndentTests: XCTestCase {

    func testIndentAddsSpacesToNonEmptyLines() {
        XCTAssertEqual(TextIndent.indent("a\nb", spaces: 2), "  a\n  b")
        XCTAssertEqual(TextIndent.indent("x\n\ny", spaces: 2), "  x\n\n  y")  // blank line untouched
    }

    func testDedentStripsCommonLeadingWhitespace() {
        XCTAssertEqual(TextIndent.dedent("    x\n      y"), "x\n  y")   // common 4 removed
        XCTAssertEqual(TextIndent.dedent("no indent here"), "no indent here")
    }

    func testDedentIgnoresBlankLinesWhenComputingCommon() {
        XCTAssertEqual(TextIndent.dedent("  a\n\n  b"), "a\n\nb")        // blank line doesn't force common to 0
    }

    func testIndentDedentRoundTrip() {
        let original = "line one\nline two"
        XCTAssertEqual(TextIndent.dedent(TextIndent.indent(original, spaces: 4)), original)
    }
}
