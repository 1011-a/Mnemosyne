import XCTest
@testable import Mnemosyne

final class CSVTypesTests: XCTestCase {

    func testInfersColumnTypes() {
        let header = ["age", "name", "active", "joined"]
        let rows = [["30", "Ada", "true", "2026-01-01"], ["25", "Bo", "false", "2025-12-31"]]
        let types = Dictionary(CSVTypes.infer(header: header, rows: rows).map { ($0.column, $0.type) },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(types["age"], "number")
        XCTAssertEqual(types["name"], "text")
        XCTAssertEqual(types["active"], "boolean")
        XCTAssertEqual(types["joined"], "date")
    }

    func testTypeOfHelper() {
        XCTAssertEqual(CSVTypes.type(of: ["1,000", "2,500"]), "number")   // thousands separators tolerated
        XCTAssertEqual(CSVTypes.type(of: ["yes", "no"]), "boolean")
        XCTAssertEqual(CSVTypes.type(of: ["1/2/2026"]), "date")
        XCTAssertEqual(CSVTypes.type(of: ["x", "5"]), "text")             // mixed → text
        XCTAssertEqual(CSVTypes.type(of: []), "empty")
    }

    func testNumericIdsAreNumberNotBoolean() {
        XCTAssertEqual(CSVTypes.type(of: ["0", "1", "1"]), "number")
    }
}
