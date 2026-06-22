import XCTest
@testable import Mnemosyne

final class PercentageTests: XCTestCase {

    func testPercentOfValue() {
        XCTAssertEqual(Percentage.of(10, 200), 20)
        XCTAssertEqual(Percentage.of(50, 50), 25)
    }

    func testWhatPercent() {
        XCTAssertEqual(Percentage.whatPercent(50, of: 200), 25)
        XCTAssertNil(Percentage.whatPercent(5, of: 0))
    }

    func testPercentChangeSignedAndZeroGuard() {
        XCTAssertEqual(Percentage.change(from: 100, to: 150), 50)
        XCTAssertEqual(Percentage.change(from: 100, to: 50), -50)
        XCTAssertNil(Percentage.change(from: 0, to: 10))
    }

    func testFormatTrimsDecimals() {
        XCTAssertEqual(Percentage.fmt(25), "25")
        XCTAssertEqual(Percentage.fmt(33.333), "33.33")
        XCTAssertEqual(Percentage.fmt(12.5), "12.5")
    }
}
