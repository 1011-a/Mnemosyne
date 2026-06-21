import XCTest
@testable import Mnemosyne

final class TagCleanupTests: XCTestCase {

    func testCanonicalNormalizesSeparatorsCasePlural() {
        XCTAssertEqual(TagCleanup.canonical("Machine-Learning"), "machinelearning")
        XCTAssertEqual(TagCleanup.canonical("machine_learning"), "machinelearning")
        XCTAssertEqual(TagCleanup.canonical("ML"), "ml")
        XCTAssertEqual(TagCleanup.canonical("notes"), "note", "trailing plural stripped on long words")
        XCTAssertEqual(TagCleanup.canonical("css"), "css", "short words keep trailing s")
        XCTAssertEqual(TagCleanup.canonical("ios"), "ios")
    }

    func testNearDuplicateClustersGroupsAndOrders() {
        // Format/case/plural variants cluster; abbreviation (ml↔machine-learning)
        // does NOT — expanding abbreviations would risk false merges.
        let tags = [("ML", 1), ("M-L", 4),
                    ("note", 3), ("notes", 5),
                    ("machine-learning", 2),   // singleton — no format-twin here
                    ("finance", 9)]            // singleton
        let clusters = TagCleanup.nearDuplicateClusters(tags)
        XCTAssertEqual(clusters.count, 2, "two near-dup groups; singletons excluded")
        // Equal-size clusters ordered alphabetically by their first (highest-count) label.
        XCTAssertEqual(clusters[0], ["M-L", "ML"], "ml family: M-L(4) before ML(1)")
        XCTAssertEqual(clusters[1], ["notes", "note"], "note family: notes(5) before note(3)")
    }

    func testNoFalsePositives() {
        let tags = [("finance", 3), ("research", 2), ("draft", 1)]
        XCTAssertTrue(TagCleanup.nearDuplicateClusters(tags).isEmpty, "distinct labels ⇒ no clusters")
    }

    func testEmptyAndBlankSafe() {
        XCTAssertTrue(TagCleanup.nearDuplicateClusters([]).isEmpty)
        XCTAssertTrue(TagCleanup.nearDuplicateClusters([("", 1), ("-", 2)]).isEmpty,
                      "blank canonical keys are skipped")
    }
}
