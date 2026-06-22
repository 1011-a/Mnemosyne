import XCTest
@testable import Mnemosyne

final class ConfidenceBandTests: XCTestCase {

    func testBands() {
        XCTAssertEqual(ConfidenceBand.describe(0.95).band, "high")
        XCTAssertEqual(ConfidenceBand.describe(0.70).band, "moderate")
        XCTAssertEqual(ConfidenceBand.describe(0.40).band, "low")
    }

    func testBoundariesAreInclusiveAtTop() {
        XCTAssertEqual(ConfidenceBand.describe(0.85).band, "high")
        XCTAssertEqual(ConfidenceBand.describe(0.60).band, "moderate")
        XCTAssertEqual(ConfidenceBand.describe(0.5999).band, "low")
    }

    func testPercentRoundsAndClamps() {
        XCTAssertEqual(ConfidenceBand.percent(0.876), 88)
        XCTAssertEqual(ConfidenceBand.percent(1.5), 100)   // clamped
        XCTAssertEqual(ConfidenceBand.percent(-0.2), 0)    // clamped
    }

    func testAdviceNonEmpty() {
        XCTAssertFalse(ConfidenceBand.describe(0.3).advice.isEmpty)
    }
}
