import XCTest
@testable import Mnemosyne

final class TextDiffTests: XCTestCase {

    func testIdenticalTextHasNoChanges() {
        let t = "line one\nline two\nline three"
        XCTAssertEqual(TextDiff.changelog(t, t), "No line-level differences.")
        XCTAssertTrue(TextDiff.lineDiff(t, t).allSatisfy { $0.op == .keep })
    }

    func testDetectsAddedAndRemovedLines() {
        let a = "alpha\nbeta\ngamma"
        let b = "alpha\ndelta\ngamma"          // beta → delta
        let diff = TextDiff.lineDiff(a, b)
        XCTAssertTrue(diff.contains(.init(op: .remove, text: "beta")))
        XCTAssertTrue(diff.contains(.init(op: .add, text: "delta")))
        XCTAssertTrue(diff.contains(.init(op: .keep, text: "alpha")))
        XCTAssertTrue(diff.contains(.init(op: .keep, text: "gamma")))

        let log = TextDiff.changelog(a, b)
        XCTAssertTrue(log.contains("1 added, 1 removed"))
        XCTAssertTrue(log.contains("- beta"))
        XCTAssertTrue(log.contains("+ delta"))
        XCTAssertFalse(log.contains("alpha"), "unchanged lines are omitted from the changelog")
    }

    func testPureInsertionAndDeletion() {
        // Pure insertion: b adds a trailing line.
        let log1 = TextDiff.changelog("a\nb", "a\nb\nc")
        XCTAssertTrue(log1.contains("1 added, 0 removed"))
        XCTAssertTrue(log1.contains("+ c"))
        // Pure deletion: b drops the middle line.
        let log2 = TextDiff.changelog("a\nb\nc", "a\nc")
        XCTAssertTrue(log2.contains("0 added, 1 removed"))
        XCTAssertTrue(log2.contains("- b"))
    }

    func testEmptyInputs() {
        XCTAssertEqual(TextDiff.changelog("", ""), "No line-level differences.")
        XCTAssertTrue(TextDiff.changelog("", "new line").contains("1 added, 0 removed"))
        XCTAssertTrue(TextDiff.changelog("old line", "").contains("0 added, 1 removed"))
    }

    func testChangelogTruncatesLongDiffs() {
        let a = (0..<200).map { "a\($0)" }.joined(separator: "\n")
        let b = (0..<200).map { "b\($0)" }.joined(separator: "\n")
        let log = TextDiff.changelog(a, b, maxLines: 10)
        XCTAssertTrue(log.contains("… (truncated)"))
        // Header + 10 change lines + truncation marker.
        XCTAssertLessThanOrEqual(log.components(separatedBy: "\n").count, 12)
    }
}
