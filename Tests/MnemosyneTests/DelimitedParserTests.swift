import XCTest
@testable import Mnemosyne

final class DelimitedParserTests: XCTestCase {

    func testParsesBasicRowsAndDropsTrailingNewline() {
        let csv = "name,age,city\nAda,36,London\nBo,29,Paris\n"
        let rows = DelimitedParser.parse(csv)
        XCTAssertEqual(rows.count, 3, "trailing newline must not add a phantom row")
        XCTAssertEqual(rows[0], ["name", "age", "city"])
        XCTAssertEqual(rows[2], ["Bo", "29", "Paris"])
    }

    func testHandlesQuotedFieldsWithCommasNewlinesAndEscapedQuotes() {
        let csv = "name,note\n\"Smith, John\",\"line1\nline2\"\n\"quote: \"\"hi\"\"\",ok"
        let rows = DelimitedParser.parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][0], "Smith, John")          // embedded comma preserved
        XCTAssertEqual(rows[1][1], "line1\nline2")          // embedded newline preserved
        XCTAssertEqual(rows[2][0], "quote: \"hi\"")         // "" → literal quote
    }

    func testDetectsTsvAndHandlesCRLF() {
        let tsv = "a\tb\tc\r\n1\t2\t3\r\n"
        XCTAssertEqual(DelimitedParser.detectDelimiter(tsv), "\t")
        let rows = DelimitedParser.parse(tsv, delimiter: "\t")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["1", "2", "3"])            // CR swallowed, no stray \r
    }

    func testSummaryReportsDimsAndClampsRows() {
        let body = (1...10).map { "\($0),x" }.joined(separator: "\n")
        let s = DelimitedParser.summary("id,val\n\(body)", previewRows: 3)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("CSV (comma)"), s ?? "")
        XCTAssertTrue(s!.contains("2 cols × 10 data rows"), s ?? "")
        XCTAssertTrue(s!.contains("+7 more rows"), s ?? "")
        XCTAssertNil(DelimitedParser.summary(""))
    }
}
