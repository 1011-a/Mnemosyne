import XCTest
@testable import Mnemosyne

final class CSVGroupByTests: XCTestCase {

    private let header = ["region", "sales"]
    private let rows = [["US", "10"], ["EU", "5"], ["US", "20"], ["EU", "15"]]

    func testCountGroups() {
        let out = CSVGroupBy.group(header: header, rows: rows, groupColumn: "region", aggColumn: nil, op: "count")
        XCTAssertEqual(out?[0], ["region", "count"])
        // Both groups count 2 → tie broken alphabetically: EU before US.
        XCTAssertEqual(Array(out!.dropFirst()), [["EU", "2"], ["US", "2"]])
    }

    func testSumSortedDescending() {
        let out = CSVGroupBy.group(header: header, rows: rows, groupColumn: "region", aggColumn: "sales", op: "sum")
        XCTAssertEqual(out?[0], ["region", "sum(sales)"])
        XCTAssertEqual(Array(out!.dropFirst()), [["US", "30"], ["EU", "20"]])   // 30 > 20
    }

    func testMeanComputed() {
        let out = CSVGroupBy.group(header: header, rows: rows, groupColumn: "region", aggColumn: "sales", op: "mean")
        let dict = Dictionary(out!.dropFirst().map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["US"], "15")   // (10+20)/2
        XCTAssertEqual(dict["EU"], "10")   // (5+15)/2
    }

    func testInvalidColumnOpOrMissingAggregate() {
        XCTAssertNil(CSVGroupBy.group(header: header, rows: rows, groupColumn: "nope", aggColumn: nil, op: "count"))
        XCTAssertNil(CSVGroupBy.group(header: header, rows: rows, groupColumn: "region", aggColumn: nil, op: "sum"))   // sum needs aggregate
        XCTAssertNil(CSVGroupBy.group(header: header, rows: rows, groupColumn: "region", aggColumn: "sales", op: "median"))
    }
}
