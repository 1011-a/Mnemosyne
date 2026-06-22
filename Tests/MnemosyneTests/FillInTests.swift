import XCTest
@testable import Mnemosyne

final class FillInTests: XCTestCase {

    func testNoSuffixReturnsUnchanged() {
        XCTAssertEqual(FillIn.trimSuffixEcho("return a + b", suffix: ""), "return a + b")
        XCTAssertEqual(FillIn.trimSuffixEcho("return a + b", suffix: "   "), "return a + b")
    }

    func testTrimsEchoedSuffix() {
        // Model generated the middle AND re-emitted the suffix.
        let generated = "a + b\n\nprint(add(1, 2))"
        XCTAssertEqual(FillIn.trimSuffixEcho(generated, suffix: "print(add(1, 2))"), "a + b\n\n")
    }

    func testSuffixNotPresentUnchanged() {
        XCTAssertEqual(FillIn.trimSuffixEcho("a + b", suffix: "XYZ"), "a + b")
    }

    func testCutsAtFirstOccurrence() {
        XCTAssertEqual(FillIn.trimSuffixEcho("middle END tail END", suffix: "END"), "middle ")
    }
}
