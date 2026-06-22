import XCTest
@testable import Mnemosyne

final class LineGrepTests: XCTestCase {

    private let doc = """
    Project kickoff notes.
    We hit an ERROR in the build.
    All good after the fix.
    Another error appeared later.
    """

    func testFindsMatchingLinesWithNumbersCaseInsensitive() {
        let matches = LineGrep.search(doc, query: "error")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].lineNumber, 2)        // "ERROR" matches case-insensitively
        XCTAssertEqual(matches[1].lineNumber, 4)
        XCTAssertEqual(matches[1].line, "Another error appeared later.")
    }

    func testNoMatchAndEmptyQuery() {
        XCTAssertTrue(LineGrep.search(doc, query: "banana").isEmpty)
        XCTAssertTrue(LineGrep.search(doc, query: "   ").isEmpty)
        XCTAssertNil(LineGrep.summary(doc, query: "banana"))
    }

    func testSummaryListsLineNumbers() {
        let s = LineGrep.summary(doc, query: "error")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("2 line(s) match 'error'"), s ?? "")
        XCTAssertTrue(s!.contains("L2:"), s ?? "")
        XCTAssertTrue(s!.contains("L4:"), s ?? "")
    }

    func testRespectsMaxCap() {
        let many = (1...10).map { "line \($0) has token" }.joined(separator: "\n")
        XCTAssertEqual(LineGrep.search(many, query: "token", max: 3).count, 3)
    }
}
