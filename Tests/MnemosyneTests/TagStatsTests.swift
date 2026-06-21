import XCTest
@testable import Mnemosyne

final class TagStatsTests: XCTestCase {

    // alpha appears on 3 items, beta on 2, gamma on 1; alpha+beta co-occur twice.
    private let lib: [[String]] = [
        ["alpha", "beta"],
        ["alpha", "beta"],
        ["alpha", "gamma"],
        []                      // an untagged item contributes nothing
    ]

    func testCountsOrderedByFrequencyThenName() {
        let c = TagStats.counts(lib)
        XCTAssertEqual(c.map(\.tag), ["alpha", "beta", "gamma"])
        XCTAssertEqual(c.map(\.count), [3, 2, 1])
    }

    func testCountsDedupesWithinAnItem() {
        // A label repeated on one item counts once for that item.
        let c = TagStats.counts([["x", "x", "y"], ["x"]])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: c.map { ($0.tag, $0.count) }), ["x": 2, "y": 1])
    }

    func testCoOccurrencePairsCountedOnceAndOrdered() {
        let co = TagStats.coOccurrences(lib)
        // Strongest pair first; pair is ordered a<b.
        XCTAssertEqual(co.first.map { [$0.a, $0.b, "\($0.count)"] }, ["alpha", "beta", "2"])
        // alpha+gamma co-occurs once.
        XCTAssertTrue(co.contains { $0.a == "alpha" && $0.b == "gamma" && $0.count == 1 })
        // No self-pairs, no reversed duplicates.
        XCTAssertFalse(co.contains { $0.a == $0.b })
        XCTAssertFalse(co.contains { $0.a == "beta" && $0.b == "alpha" }, "pairs are ordered a<b")
    }

    func testSummaryHighlightsCountsAndStrongPairs() {
        let s = TagStats.summary(lib)
        XCTAssertTrue(s.contains("alpha (3)"))
        XCTAssertTrue(s.contains("Often together — alpha+beta (2)"), "only pairs with ≥2 shared items: \(s)")
        XCTAssertFalse(s.contains("alpha+gamma"), "single co-occurrence is below the ≥2 threshold")
    }

    func testCoveragePercentAndText() {
        let c1 = TagStats.coverage(labelled: 3, total: 4)
        XCTAssertEqual(c1.pct, 75)
        XCTAssertEqual(c1.text, "75% of files labelled (3 of 4)")
        XCTAssertEqual(TagStats.coverage(labelled: 1, total: 3).pct, 33, "rounds to nearest percent")
        let none = TagStats.coverage(labelled: 0, total: 0)
        XCTAssertEqual(none.pct, 0); XCTAssertEqual(none.text, "No files yet.")
        XCTAssertEqual(TagStats.coverage(labelled: 10, total: 4).pct, 100, "labelled clamped to total")
        XCTAssertEqual(TagStats.coverage(labelled: 5, total: 5).pct, 100)
    }

    func testEmptyLibrary() {
        XCTAssertEqual(TagStats.summary([]), "No labels yet.")
        XCTAssertEqual(TagStats.summary([[], []]), "No labels yet.")
        XCTAssertTrue(TagStats.coOccurrences([["solo"]]).isEmpty, "a lone tag has no pairs")
    }
}
