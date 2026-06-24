import XCTest
@testable import Mnemosyne

/// Guards the final-answer scrubbing that strips tool-call / function-call markup the model leaks
/// into its prose (see ToolAgent.stripLeakedToolMarkup / finalAnswerDirective).
final class LeakedToolMarkupTests: XCTestCase {

    func testCleanProseUnchanged() {
        let s = "Here is the answer, grounded in [1] and [2]. Nothing leaked here."
        XCTAssertEqual(ToolAgent.stripLeakedToolMarkup(s), s)
    }

    func testCutsProseThenLeak() {
        let s = "The summary is solid [1].\n<invoke name=\"get_item\"><parameter name=\"item\">x</parameter></invoke>"
        XCTAssertEqual(ToolAgent.stripLeakedToolMarkup(s), "The summary is solid [1].")
    }

    func testEntireAnswerIsLeakBecomesEmpty() {
        let s = "<tool_calls><invoke name=\"get_item\"><parameter name=\"item\">资料.doc</parameter></invoke></tool_calls>"
        XCTAssertEqual(ToolAgent.stripLeakedToolMarkup(s), "")
    }

    func testNamespacePrefixedTagsDetected() {
        // The model leaked Anthropic-style tags with a namespace prefix.
        let s = "Done.\n<function_calls><invoke name=\"get_item\">"
        XCTAssertEqual(ToolAgent.stripLeakedToolMarkup(s), "Done.")
    }

    func testEarliestOpeningWins() {
        // A <parameter> appears after an earlier <invoke>; cut at the earliest.
        let s = "Prose.<invoke a><parameter b>"
        XCTAssertEqual(ToolAgent.stripLeakedToolMarkup(s), "Prose.")
    }

    func testStrayAngleBracketNotCut() {
        // Legitimate prose with comparisons / generics must not be truncated.
        let s = "If a < b and List<String> is used, the result holds. invoke is just a word."
        XCTAssertEqual(ToolAgent.stripLeakedToolMarkup(s), s)
        XCTAssertNil(ToolAgent.leakedToolMarkupStart(s))
    }

    func testLeakStartIndexNilWhenClean() {
        XCTAssertNil(ToolAgent.leakedToolMarkupStart("totally clean prose [1]"))
        XCTAssertNotNil(ToolAgent.leakedToolMarkupStart("oops <tool_calls>"))
    }
}
