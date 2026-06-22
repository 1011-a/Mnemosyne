import XCTest
@testable import Mnemosyne

final class CSVSorterTests: XCTestCase {

    private let header = ["name", "age"]
    private let rows = [["Bob", "30"], ["Ada", "25"], ["Cy", "40"]]

    func testSortsByTextColumn() {
        let out = CSVSorter.sort(header: header, rows: rows, column: "name")
        XCTAssertEqual(out?.map { $0[0] }, ["name", "Ada", "Bob", "Cy"])   // header kept first
    }

    func testNumericSortBeatsLexicographic() {
        let numeric = CSVSorter.sort(header: header, rows: [["A", "100"], ["B", "9"], ["C", "20"]],
                                     column: "age", numeric: true)
        XCTAssertEqual(numeric?.dropFirst().map { $0[1] }, ["9", "20", "100"])
        let text = CSVSorter.sort(header: header, rows: [["A", "100"], ["B", "9"], ["C", "20"]], column: "age")
        XCTAssertEqual(text?.dropFirst().map { $0[1] }, ["100", "20", "9"])   // "100" < "20" < "9" lexically
    }

    func testDescendingAndCaseInsensitiveColumn() {
        let out = CSVSorter.sort(header: header, rows: rows, column: "NAME", descending: true)
        XCTAssertEqual(out?.dropFirst().map { $0[0] }, ["Cy", "Bob", "Ada"])
    }

    func testMissingColumnIsNil() {
        XCTAssertNil(CSVSorter.sort(header: header, rows: rows, column: "salary"))
    }
}
