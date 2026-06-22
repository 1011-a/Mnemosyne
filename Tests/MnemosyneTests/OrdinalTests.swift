import XCTest
@testable import Mnemosyne

final class OrdinalTests: XCTestCase {

    func testBasicSuffixes() {
        XCTAssertEqual(Ordinal.format(1), "1st")
        XCTAssertEqual(Ordinal.format(2), "2nd")
        XCTAssertEqual(Ordinal.format(3), "3rd")
        XCTAssertEqual(Ordinal.format(4), "4th")
        XCTAssertEqual(Ordinal.format(23), "23rd")
    }

    func testElevenTwelveThirteenAreTh() {
        XCTAssertEqual(Ordinal.format(11), "11th")
        XCTAssertEqual(Ordinal.format(12), "12th")
        XCTAssertEqual(Ordinal.format(13), "13th")
        XCTAssertEqual(Ordinal.format(111), "111th")
        XCTAssertEqual(Ordinal.format(113), "113th")
    }

    func testHundredsKeepUnitRule() {
        XCTAssertEqual(Ordinal.format(101), "101st")
        XCTAssertEqual(Ordinal.format(102), "102nd")
        XCTAssertEqual(Ordinal.format(100), "100th")
    }
}
