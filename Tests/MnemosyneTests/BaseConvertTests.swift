import XCTest
@testable import Mnemosyne

final class BaseConvertTests: XCTestCase {

    func testCommonConversions() {
        XCTAssertEqual(BaseConvert.convert("FF", from: 16, to: 10), "255")
        XCTAssertEqual(BaseConvert.convert("255", from: 10, to: 16), "ff")
        XCTAssertEqual(BaseConvert.convert("255", from: 10, to: 2), "11111111")
        XCTAssertEqual(BaseConvert.convert("1010", from: 2, to: 10), "10")
    }

    func testBase36AndCaseInsensitive() {
        XCTAssertEqual(BaseConvert.convert("z", from: 36, to: 10), "35")
        XCTAssertEqual(BaseConvert.convert("Z", from: 36, to: 10), "35")
    }

    func testNegativeAndRoundTrip() {
        XCTAssertEqual(BaseConvert.convert("-10", from: 10, to: 2), "-1010")
        let mid = BaseConvert.convert("12345", from: 10, to: 16)!
        XCTAssertEqual(BaseConvert.convert(mid, from: 16, to: 10), "12345")
    }

    func testInvalidBaseOrDigits() {
        XCTAssertNil(BaseConvert.convert("10", from: 1, to: 10))    // base too small
        XCTAssertNil(BaseConvert.convert("10", from: 10, to: 37))   // base too large
        XCTAssertNil(BaseConvert.convert("G", from: 16, to: 10))    // invalid hex digit
    }
}
