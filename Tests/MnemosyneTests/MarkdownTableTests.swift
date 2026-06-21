import XCTest
@testable import Mnemosyne

final class MarkdownTableTests: XCTestCase {

    func testBuildsAlignedTableFromCommaRows() {
        let table = MarkdownTable.make("Name,Age\nAda,36")
        XCTAssertEqual(table, """
        | Name | Age |
        | ---- | --- |
        | Ada  | 36  |
        """)
    }

    func testAutodetectsPipeDelimiterAndStripsOuterPipes() {
        let table = MarkdownTable.make("| a | b |\n| 1 | 2 |")
        XCTAssertNotNil(table)
        let lines = table!.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)               // header, separator, one data row
        XCTAssertTrue(lines[0].contains("a"))
        XCTAssertTrue(lines[0].contains("b"))
        XCTAssertTrue(lines[2].contains("1") && lines[2].contains("2"))
    }

    func testRaggedRowsArePaddedToColumnCount() {
        let table = MarkdownTable.make("A,B,C\n1,2")    // second row missing a cell
        XCTAssertNotNil(table)
        // Every line has the same number of pipes (4 for 3 columns).
        for line in table!.components(separatedBy: "\n") {
            XCTAssertEqual(line.filter { $0 == "|" }.count, 4, line)
        }
    }

    func testEmptyIsNil() {
        XCTAssertNil(MarkdownTable.make(""))
        XCTAssertNil(MarkdownTable.make("   \n  "))
    }

    func testTableFromParsedRowsMatchesMake() {
        // The shared core used by csv_to_table produces the same output as make().
        let rows = [["Name", "Age"], ["Ada", "36"]]
        XCTAssertEqual(MarkdownTable.tableFrom(rows), MarkdownTable.make("Name,Age\nAda,36"))
        XCTAssertNil(MarkdownTable.tableFrom([]))
    }
}
