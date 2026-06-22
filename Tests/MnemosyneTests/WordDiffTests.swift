import XCTest
@testable import Mnemosyne

final class WordDiffTests: XCTestCase {

    func testAddedAndRemoved() {
        let d = WordDiff.diff("the quick brown fox", "the slow brown fox")
        XCTAssertEqual(d.added, ["slow"])
        XCTAssertEqual(d.removed, ["quick"])
    }

    func testMultisetCounts() {
        let d = WordDiff.diff("a a b", "a b b")
        XCTAssertEqual(d.added, ["b"])     // b went 1 → 2
        XCTAssertEqual(d.removed, ["a"])   // a went 2 → 1
    }

    func testCaseInsensitiveAndPunctuation() {
        let d = WordDiff.diff("Hello, world!", "hello world")
        XCTAssertTrue(d.added.isEmpty, "\(d.added)")
        XCTAssertTrue(d.removed.isEmpty, "\(d.removed)")
    }

    func testSummaryIdenticalAndChanged() {
        XCTAssertEqual(WordDiff.summary("same text", "same text"), "No word-level differences.")
        let s = WordDiff.summary("keep drop", "keep add")
        XCTAssertTrue(s.contains("Added: add"), s)
        XCTAssertTrue(s.contains("Removed: drop"), s)
    }
}
