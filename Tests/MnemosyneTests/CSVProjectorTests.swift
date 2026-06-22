import XCTest
@testable import Mnemosyne

final class CSVProjectorTests: XCTestCase {

    private let header = ["name", "age", "city"]
    private let rows = [["Ada", "36", "London"], ["Bo", "29", "Paris"]]

    func testSelectsAndReordersColumns() {
        let out = CSVProjector.select(header: header, rows: rows, columns: ["city", "name"])
        XCTAssertEqual(out?[0], ["city", "name"])         // reordered header
        XCTAssertEqual(out?[1], ["London", "Ada"])
        XCTAssertEqual(out?[2], ["Paris", "Bo"])
    }

    func testCaseInsensitiveColumnMatch() {
        let out = CSVProjector.select(header: header, rows: rows, columns: ["NAME"])
        XCTAssertEqual(out?[0], ["name"])
        XCTAssertEqual(out?[1], ["Ada"])
    }

    func testMissingColumnIsNil() {
        XCTAssertNil(CSVProjector.select(header: header, rows: rows, columns: ["name", "salary"]))
        XCTAssertNil(CSVProjector.select(header: header, rows: rows, columns: []))
    }

    func testRaggedRowsFillBlank() {
        let out = CSVProjector.select(header: header, rows: [["Ada"]], columns: ["name", "city"])
        XCTAssertEqual(out?[1], ["Ada", ""])              // missing city cell → ""
    }
}
