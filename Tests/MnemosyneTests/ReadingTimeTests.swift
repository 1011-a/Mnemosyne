import XCTest
@testable import Mnemosyne

final class ReadingTimeTests: XCTestCase {

    func testWordCountSplitsOnWhitespaceAndNewlines() {
        XCTAssertEqual(ReadingTime.words("one two\nthree   four\tfive"), 5)
        XCTAssertEqual(ReadingTime.words("   "), 0)
        XCTAssertEqual(ReadingTime.words(""), 0)
    }

    func testMinutesRoundAndFloorAtOne() {
        // 220 wpm: 220 words → 1 min, 440 → 2 min.
        let w220 = Array(repeating: "word", count: 220).joined(separator: " ")
        XCTAssertEqual(ReadingTime.estimate(w220).minutes, 1)
        let w440 = Array(repeating: "word", count: 440).joined(separator: " ")
        XCTAssertEqual(ReadingTime.estimate(w440).minutes, 2)
        // A short doc still reads in at least 1 minute.
        XCTAssertEqual(ReadingTime.estimate("just a few words").minutes, 1)
        // Empty ⇒ 0 words, 0 minutes.
        XCTAssertEqual(ReadingTime.estimate("").minutes, 0)
    }

    func testSummary() {
        let w = Array(repeating: "word", count: 220).joined(separator: " ")
        XCTAssertEqual(ReadingTime.summary(w), "220 words · about 1 min read")
        XCTAssertEqual(ReadingTime.summary(""), "Empty — nothing to read.")
    }
}
