import XCTest
@testable import Mnemosyne

final class ColorConvertTests: XCTestCase {

    func testHexToRGBIncludingShorthand() {
        XCTAssertTrue(ColorConvert.hexToRGB("#FF5733")! == (255, 87, 51))
        XCTAssertTrue(ColorConvert.hexToRGB("FF5733")! == (255, 87, 51))
        XCTAssertTrue(ColorConvert.hexToRGB("#fff")! == (255, 255, 255))
        XCTAssertNil(ColorConvert.hexToRGB("#GG0000"))
        XCTAssertNil(ColorConvert.hexToRGB("#12345"))
    }

    func testRGBToHexClamps() {
        XCTAssertEqual(ColorConvert.rgbToHex(255, 87, 51), "#FF5733")
        XCTAssertNil(ColorConvert.rgbToHex(256, 0, 0))
        XCTAssertNil(ColorConvert.rgbToHex(-1, 0, 0))
    }

    func testDescribeAutoDetectsDirection() {
        XCTAssertEqual(ColorConvert.describe("#FF5733"), "#FF5733 = rgb(255, 87, 51)")
        XCTAssertEqual(ColorConvert.describe("255, 87, 51"), "rgb(255, 87, 51) = #FF5733")
        XCTAssertEqual(ColorConvert.describe("#fff"), "#FFFFFF = rgb(255, 255, 255)")
    }

    func testInvalidIsNil() {
        XCTAssertNil(ColorConvert.describe("notacolor"))
        XCTAssertNil(ColorConvert.describe("999,0,0"))
    }
}
