import XCTest
@testable import Mnemosyne

final class TableExtractorTests: XCTestCase {

    func testParsesHeadersAndRows() {
        let text = """
        Intro prose.

        | Name | Role  | City  |
        |------|-------|-------|
        | Ada  | Eng   | London|
        | Bo   | Design| Paris |

        Trailing prose.
        """
        let tables = TableExtractor.extract(text)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].headers, ["Name", "Role", "City"])
        XCTAssertEqual(tables[0].rows.count, 2)
        XCTAssertEqual(tables[0].rows[0], ["Ada", "Eng", "London"])
        XCTAssertEqual(tables[0].rows[1], ["Bo", "Design", "Paris"])
    }

    func testHandlesAlignmentColonsAndNoOuterPipes() {
        let text = """
        Col A | Col B
        :--- | ---:
        1 | 2
        """
        let tables = TableExtractor.extract(text)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].headers, ["Col A", "Col B"])
        XCTAssertEqual(tables[0].rows, [["1", "2"]])
    }

    func testIgnoresNonTablesAndPipelessText() {
        // A pipe-bearing line with no separator underneath is not a table.
        XCTAssertTrue(TableExtractor.extract("a | b | c\njust prose, no separator").isEmpty)
        XCTAssertTrue(TableExtractor.extract("no pipes here at all").isEmpty)
        XCTAssertTrue(TableExtractor.extract("").isEmpty)
        XCTAssertNil(TableExtractor.summary("nothing tabular"))
    }

    func testSummaryReportsDimsAndClampsRows() {
        let rows = (1...10).map { "| \($0) | x |" }.joined(separator: "\n")
        let text = "| N | V |\n|---|---|\n\(rows)"
        let s = TableExtractor.summary(text, previewRows: 3)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("1 table"))
        XCTAssertTrue(s!.contains("2 cols × 10 rows"), s ?? "")
        XCTAssertTrue(s!.contains("+7 more rows"), s ?? "")
    }
}
