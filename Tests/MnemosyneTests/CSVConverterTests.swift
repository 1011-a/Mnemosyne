import XCTest
@testable import Mnemosyne

final class CSVConverterTests: XCTestCase {

    /// Round-trip through JSONSerialization to avoid asserting on pretty-print spacing.
    private func parse(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr
    }

    func testBuildsObjectsFromHeaderAndRows() {
        let json = CSVConverter.toJSON([["name", "age"], ["Ada", "36"], ["Bo", "7"]])
        XCTAssertNotNil(json)
        let objs = parse(json!)
        XCTAssertEqual(objs?.count, 2)
        XCTAssertEqual(objs?[0]["name"] as? String, "Ada")
        XCTAssertEqual(objs?[0]["age"] as? String, "36")     // values stay strings
        XCTAssertEqual(objs?[1]["name"] as? String, "Bo")
    }

    func testRaggedRowsFillMissingWithEmptyString() {
        let json = CSVConverter.toJSON([["a", "b"], ["1"]])   // row missing "b"
        let objs = parse(json!)
        XCTAssertEqual(objs?[0]["a"] as? String, "1")
        XCTAssertEqual(objs?[0]["b"] as? String, "")
    }

    func testHeaderOnlyIsEmptyArrayAndNoRowsIsNil() {
        XCTAssertEqual(CSVConverter.toJSON([["a", "b"]]), "[]")
        XCTAssertNil(CSVConverter.toJSON([]))
    }

    func testSortedKeysAreDeterministic() {
        let json = CSVConverter.toJSON([["zeta", "alpha"], ["1", "2"]])!
        // sortedKeys → "alpha" key appears before "zeta" in the serialized text.
        XCTAssertTrue(json.range(of: "alpha")!.lowerBound < json.range(of: "zeta")!.lowerBound, json)
    }
}
