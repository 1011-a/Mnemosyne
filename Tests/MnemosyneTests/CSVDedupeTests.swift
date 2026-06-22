import XCTest
@testable import Mnemosyne

final class CSVDedupeTests: XCTestCase {

    private let header = ["name", "city"]

    func testExactWholeRowDedupe() {
        let rows = [["Ada", "London"], ["Bo", "Paris"], ["Ada", "London"]]
        let out = CSVDedupe.dedupe(header: header, rows: rows, keyColumn: nil)
        XCTAssertEqual(out?.removed, 1)
        XCTAssertEqual(out?.rows, [["Ada", "London"], ["Bo", "Paris"]])
    }

    func testKeepsRowsThatDifferInAnyColumn() {
        let rows = [["Ada", "London"], ["Ada", "Paris"]]   // same name, different city
        let out = CSVDedupe.dedupe(header: header, rows: rows, keyColumn: nil)
        XCTAssertEqual(out?.removed, 0)
    }

    func testDedupeByKeyColumnKeepsFirst() {
        let rows = [["Ada", "London"], ["Ada", "Paris"], ["Bo", "Rome"]]
        let out = CSVDedupe.dedupe(header: header, rows: rows, keyColumn: "name")
        XCTAssertEqual(out?.removed, 1)
        XCTAssertEqual(out?.rows, [["Ada", "London"], ["Bo", "Rome"]])   // first Ada kept
    }

    func testMissingKeyColumnIsNil() {
        XCTAssertNil(CSVDedupe.dedupe(header: header, rows: [["Ada", "London"]], keyColumn: "salary"))
    }
}
