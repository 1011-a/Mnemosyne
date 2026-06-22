import XCTest
@testable import Mnemosyne

final class LevenshteinTests: XCTestCase {

    func testKnownDistances() {
        XCTAssertEqual(Levenshtein.distance("kitten", "sitting"), 3)   // classic example
        XCTAssertEqual(Levenshtein.distance("flaw", "lawn"), 2)
        XCTAssertEqual(Levenshtein.distance("abc", "abc"), 0)
    }

    func testEmptyStrings() {
        XCTAssertEqual(Levenshtein.distance("", "abc"), 3)
        XCTAssertEqual(Levenshtein.distance("abc", ""), 3)
        XCTAssertEqual(Levenshtein.distance("", ""), 0)
    }

    func testRatio() {
        XCTAssertEqual(Levenshtein.ratio("abc", "abc"), 1.0)
        XCTAssertEqual(Levenshtein.ratio("", ""), 1.0)
        XCTAssertEqual(Levenshtein.ratio("kitten", "sitting"), 1.0 - 3.0 / 7.0, accuracy: 1e-9)
    }

    func testSymmetric() {
        XCTAssertEqual(Levenshtein.distance("sunday", "saturday"), Levenshtein.distance("saturday", "sunday"))
    }
}
