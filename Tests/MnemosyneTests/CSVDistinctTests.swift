import XCTest
@testable import Mnemosyne

final class CSVDistinctTests: XCTestCase {

    private let header = ["region", "amount"]
    private let rows = [["US", "10"], ["EU", "5"], ["US", "20"], ["", "1"]]

    func testUniqueSortedValues() {
        XCTAssertEqual(CSVDistinct.values(header: header, rows: rows, column: "region"), ["EU", "US"])
    }

    func testCaseInsensitiveColumnAndSkipsBlanks() {
        // The empty region cell is excluded.
        XCTAssertEqual(CSVDistinct.values(header: header, rows: rows, column: "REGION"), ["EU", "US"])
    }

    func testNumericColumnValues() {
        XCTAssertEqual(CSVDistinct.values(header: header, rows: rows, column: "amount"), ["1", "10", "20", "5"])
    }

    func testMissingColumnIsNil() {
        XCTAssertNil(CSVDistinct.values(header: header, rows: rows, column: "city"))
    }
}
