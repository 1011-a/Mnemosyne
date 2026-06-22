import XCTest
@testable import Mnemosyne

final class TokenEstimateTests: XCTestCase {

    func testLatinIsAboutCharsOverFour() {
        XCTAssertEqual(TokenEstimate.estimate("hello world"), 3)   // 11 chars → ceil(2.75)
        XCTAssertEqual(TokenEstimate.estimate("a"), 1)
    }

    func testCJKCountsMuchHigherThanCharsOverFour() {
        // 3 Han chars → ceil(4.5) = 5, NOT 3/4 ≈ 1.
        XCTAssertEqual(TokenEstimate.estimate("曲目二"), 5)
        // The whole point: CJK estimate dwarfs the naive chars/4.
        let cjk = String(repeating: "字", count: 100)
        XCTAssertGreaterThan(TokenEstimate.estimate(cjk), cjk.count / 4 * 3)
    }

    func testMixedScriptAddsBothParts() {
        // "ok 好" → 'o','k',' ' = 3 other (0.75) + 1 CJK (1.5) = 2.25 → ceil 3
        XCTAssertEqual(TokenEstimate.estimate("ok 好"), 3)
    }

    func testEmptyIsZeroAndKanaHangulDetected() {
        XCTAssertEqual(TokenEstimate.estimate(""), 0)
        XCTAssertTrue(TokenEstimate.isCJK(Unicode.Scalar(0x3042)!))   // あ hiragana
        XCTAssertTrue(TokenEstimate.isCJK(Unicode.Scalar(0xAC00)!))   // 가 hangul
        XCTAssertFalse(TokenEstimate.isCJK(Unicode.Scalar("A")))
    }
}
