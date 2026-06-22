import XCTest
@testable import Mnemosyne

final class LineDiffTests: XCTestCase {

    func testIdenticalHasNoChanges() {
        let r = LineDiff.diff("a\nb\nc", "a\nb\nc")
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.lines, ["  a", "  b", "  c"])
    }

    func testAddedAndRemovedLines() {
        // a,b,c  →  a,x,c : 'b' removed, 'x' added, a/c unchanged.
        let r = LineDiff.diff("a\nb\nc", "a\nx\nc")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.lines, ["  a", "- b", "+ x", "  c"])
    }

    func testPureInsertionKeepsCommonContext() {
        // Insert a line in the middle — LCS keeps a & b unchanged.
        let r = LineDiff.diff("a\nb", "a\nNEW\nb")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.lines, ["  a", "+ NEW", "  b"])
    }

    func testEmptyToContentIsAllAdded() {
        let r = LineDiff.diff("", "x\ny")
        XCTAssertEqual(r.removed, 1)   // "" is one (empty) line removed
        XCTAssertEqual(r.added, 2)
    }
}
