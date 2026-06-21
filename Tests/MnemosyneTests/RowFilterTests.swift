import XCTest
@testable import Mnemosyne

final class RowFilterTests: XCTestCase {

    private let headers = ["name", "amount", "status"]
    private let rows = [
        ["Ada", "1200", "open"],
        ["Bo",  "300",  "closed"],
        ["Cy",  "500",  "open"],
    ]

    func testParsesOperatorsIncludingMultiCharAndContains() {
        XCTAssertEqual(RowFilter.parse("amount >= 500"), .init(column: "amount", op: .ge, value: "500"))
        XCTAssertEqual(RowFilter.parse("x != 1"), .init(column: "x", op: .ne, value: "1"))
        XCTAssertEqual(RowFilter.parse("status = open"), .init(column: "status", op: .eq, value: "open"))
        XCTAssertEqual(RowFilter.parse("name contains da"), .init(column: "name", op: .contains, value: "da"))
        XCTAssertEqual(RowFilter.parse("city = \"New York\"")?.value, "New York", "quotes stripped")
        XCTAssertNil(RowFilter.parse("no operator here"))
    }

    func testMatchesNumericAndStringSemantics() {
        XCTAssertTrue(RowFilter.matches(cell: "500", op: .ge, value: "500"))    // numeric >=
        XCTAssertTrue(RowFilter.matches(cell: "500.0", op: .eq, value: "500"))  // 500.0 == 500
        XCTAssertFalse(RowFilter.matches(cell: "300", op: .gt, value: "500"))
        XCTAssertTrue(RowFilter.matches(cell: "Open", op: .eq, value: "open"))  // case-insensitive
        XCTAssertTrue(RowFilter.matches(cell: "Ada Lovelace", op: .contains, value: "love"))
    }

    func testEvaluateNumericFilter() {
        guard case let .ok(p, matched) = RowFilter.evaluate(headers: headers, rows: rows, expr: "amount >= 500") else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(p.op, .ge)
        XCTAssertEqual(matched.map { $0[0] }, ["Ada", "Cy"])   // 1200 and 500, not 300
    }

    func testEvaluateBadPredicateAndMissingColumn() {
        if case .badPredicate = RowFilter.evaluate(headers: headers, rows: rows, expr: "gibberish") {} else {
            XCTFail("expected badPredicate")
        }
        if case let .noColumn(cols) = RowFilter.evaluate(headers: headers, rows: rows, expr: "nope = 1") {
            XCTAssertEqual(cols, headers)
        } else {
            XCTFail("expected noColumn")
        }
    }
}
