import XCTest
@testable import Mnemosyne

final class ListOpsTests: XCTestCase {

    private let a = "x\ny\nz"
    private let b = "y\nz\nw"

    func testCommonAndDifferences() {
        XCTAssertEqual(ListOps.compare(a, b, op: "common"), ["y", "z"])
        XCTAssertEqual(ListOps.compare(a, b, op: "only_a"), ["x"])
        XCTAssertEqual(ListOps.compare(a, b, op: "only_b"), ["w"])
    }

    func testUnionIsSortedAndDeduped() {
        XCTAssertEqual(ListOps.compare(a, b, op: "union"), ["w", "x", "y", "z"])
        // Duplicates within a list collapse.
        XCTAssertEqual(ListOps.compare("a\na\nb", "b", op: "union"), ["a", "b"])
    }

    func testTrimsBlanksAndUnknownOpIsNil() {
        XCTAssertEqual(ListOps.compare("  x \n\n y ", "y", op: "common"), ["y"])
        XCTAssertNil(ListOps.compare(a, b, op: "xor"))
    }

    func testEmptyIntersectionIsEmptyNotNil() {
        XCTAssertEqual(ListOps.compare("a\nb", "c\nd", op: "common"), [])
    }
}
