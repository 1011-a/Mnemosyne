import XCTest
@testable import Mnemosyne

final class LineSorterTests: XCTestCase {

    func testAlphabeticalCaseInsensitiveAndDropsBlanks() {
        XCTAssertEqual(LineSorter.sort("banana\n\napple\nCherry"), "apple\nbanana\nCherry")
    }

    func testNumericSortBeatsLexicographic() {
        XCTAssertEqual(LineSorter.sort("10\n2\n1", numeric: true), "1\n2\n10")
        // Lexicographic (default) would order these differently.
        XCTAssertEqual(LineSorter.sort("10\n2\n1"), "1\n10\n2")
    }

    func testDescendingAndUnique() {
        XCTAssertEqual(LineSorter.sort("a\nc\nb", descending: true), "c\nb\na")
        XCTAssertEqual(LineSorter.sort("b\na\nb\na", unique: true), "a\nb")
        XCTAssertEqual(LineSorter.sort("b\na\nb\na", unique: true, numeric: false), "a\nb")
    }

    func testNumbersBeforeNonNumbersInNumericMode() {
        XCTAssertEqual(LineSorter.sort("apple\n3\n1", numeric: true), "1\n3\napple")
    }
}
