import XCTest
@testable import Mnemosyne

final class JSONTableTests: XCTestCase {

    func testArrayOfObjectsBecomesColumnsPerKey() {
        let rows = JSONTable.rows(from: #"[{"name":"Ada","age":36},{"name":"Bo","age":7}]"#)
        XCTAssertEqual(rows?[0], ["age", "name"])     // union of keys, sorted
        XCTAssertEqual(rows?[1], ["36", "Ada"])
        XCTAssertEqual(rows?[2], ["7", "Bo"])
    }

    func testMissingKeysFillBlank() {
        let rows = JSONTable.rows(from: #"[{"a":1},{"a":2,"b":3}]"#)
        XCTAssertEqual(rows?[0], ["a", "b"])
        XCTAssertEqual(rows?[1], ["1", ""])           // first object lacks "b"
        XCTAssertEqual(rows?[2], ["2", "3"])
    }

    func testSingleObjectBecomesKeyValueTable() {
        let rows = JSONTable.rows(from: #"{"city":"London","zip":12345}"#)
        XCTAssertEqual(rows?[0], ["key", "value"])
        XCTAssertEqual(rows?[1], ["city", "London"])
        XCTAssertEqual(rows?[2], ["zip", "12345"])
    }

    func testArrayOfScalarsAndInvalidIsNil() {
        XCTAssertEqual(JSONTable.rows(from: "[1,2,3]"), [["value"], ["1"], ["2"], ["3"]])
        XCTAssertNil(JSONTable.rows(from: "42"))          // bare scalar can't tabulate
        XCTAssertNil(JSONTable.rows(from: "not json {"))
    }
}
