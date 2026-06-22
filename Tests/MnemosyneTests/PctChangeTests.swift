import XCTest
@testable import Mnemosyne

final class PctChangeTests: XCTestCase {

    func testBasicChanges() {
        let s = PctChange.series([100, 110, 99])
        XCTAssertEqual(s?.count, 2)
        XCTAssertEqual(s?[0] ?? 0, 10, accuracy: 1e-9)    // 100 → 110
        XCTAssertEqual(s?[1] ?? 0, -10, accuracy: 1e-9)   // 110 → 99
    }

    func testDivisionByZeroIsNil() {
        let s = PctChange.series([10, 0, 5])
        XCTAssertEqual(s?[0] ?? 0, -100, accuracy: 1e-9)  // 10 → 0
        XCTAssertNil(s?[1] ?? Optional(0.0).flatMap { _ in nil })   // 0 → 5 undefined
        XCTAssertNil(s![1])
    }

    func testNegativeBaseHandled() {
        // Standard formula (new−old)/old with a negative base: (−25−(−50))/(−50) = 25/−50 = −50%.
        // (The signed denominator makes this counterintuitive, but it's the conventional result.)
        XCTAssertEqual(PctChange.series([-50, -25])![0]!, -50, accuracy: 1e-9)
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(PctChange.series([5]))
        XCTAssertNil(PctChange.series([]))
    }
}
