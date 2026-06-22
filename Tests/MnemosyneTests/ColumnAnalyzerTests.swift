import XCTest
@testable import Mnemosyne

final class ColumnAnalyzerTests: XCTestCase {

    private let headers = ["name", "amount", "status"]
    private let rows = [
        ["Ada", "$1,200", "open"],
        ["Bo",  "300",    "closed"],
        ["Cy",  "500",    "open"],
        ["Di",  "",       "open"],   // blank amount → excluded from amount stats
    ]

    func testNumericColumnAggregates() {
        let s = ColumnAnalyzer.analyze(headers: headers, rows: rows, column: "amount")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.count, 3)                  // blank excluded
        XCTAssertNotNil(s?.numeric)
        XCTAssertEqual(s?.numeric?.sum, 2000)        // 1200 + 300 + 500, currency/commas stripped
        XCTAssertEqual(s?.numeric?.mean, 2000.0 / 3)
        XCTAssertEqual(s?.numeric?.min, 300)
        XCTAssertEqual(s?.numeric?.max, 1200)
    }

    func testCategoricalColumnTopValues() {
        let s = ColumnAnalyzer.analyze(headers: headers, rows: rows, column: "STATUS") // case-insensitive
        XCTAssertNotNil(s)
        XCTAssertNil(s?.numeric, "non-numeric column has no numeric stats")
        XCTAssertEqual(s?.count, 4)
        XCTAssertEqual(s?.unique, 2)
        XCTAssertEqual(s?.top.first?.value, "open")
        XCTAssertEqual(s?.top.first?.count, 3)
    }

    func testMissingColumnReturnsNil() {
        XCTAssertNil(ColumnAnalyzer.analyze(headers: headers, rows: rows, column: "nope"))
        XCTAssertNil(ColumnAnalyzer.report(headers: headers, rows: rows, column: "nope"))
    }

    func testReportFormatsNumericAndCategorical() {
        let num = ColumnAnalyzer.report(headers: headers, rows: rows, column: "amount")
        XCTAssertNotNil(num)
        XCTAssertTrue(num!.contains("sum=2000"), num ?? "")
        XCTAssertTrue(num!.contains("min=300"), num ?? "")

        let cat = ColumnAnalyzer.report(headers: headers, rows: rows, column: "status")
        XCTAssertNotNil(cat)
        XCTAssertTrue(cat!.contains("Top values: open (3)"), cat ?? "")
        XCTAssertFalse(cat!.contains("Numeric:"), "categorical report omits numeric line")
    }
}
