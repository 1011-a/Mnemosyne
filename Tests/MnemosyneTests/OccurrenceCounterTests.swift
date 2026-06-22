import XCTest
@testable import Mnemosyne

final class OccurrenceCounterTests: XCTestCase {

    func testCaseInsensitiveByDefault() {
        XCTAssertEqual(OccurrenceCounter.count(in: "The cat sat. CAT!", needle: "cat"), 2)
    }

    func testCaseSensitive() {
        XCTAssertEqual(OccurrenceCounter.count(in: "Cat cat CAT", needle: "cat", caseSensitive: true), 1)
    }

    func testNonOverlapping() {
        // "aaaa" contains "aa" twice non-overlapping, not three times.
        XCTAssertEqual(OccurrenceCounter.count(in: "aaaa", needle: "aa"), 2)
    }

    func testWholeWord() {
        XCTAssertEqual(OccurrenceCounter.count(in: "cat category catalog cat", needle: "cat", wholeWord: true), 2)
        XCTAssertEqual(OccurrenceCounter.count(in: "cat category catalog cat", needle: "cat"), 4)
    }

    func testEmptyNeedleNilAndNoMatchZero() {
        XCTAssertNil(OccurrenceCounter.count(in: "hello", needle: ""))
        XCTAssertEqual(OccurrenceCounter.count(in: "hello", needle: "z"), 0)
        XCTAssertEqual(OccurrenceCounter.count(in: "hi", needle: "longer than hay"), 0)
    }
}
