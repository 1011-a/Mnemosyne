import XCTest
import Fathom
@testable import Mnemosyne

final class UnitConvertTests: XCTestCase {

    private func conv(_ v: Double, _ from: String, _ to: String) -> Double? {
        UnitConvert.convert(v, from: from, to: to)
    }

    func testLength() {
        XCTAssertEqual(conv(1, "km", "m")!, 1000, accuracy: 1e-9)
        XCTAssertEqual(conv(12, "in", "ft")!, 1, accuracy: 1e-9)
        XCTAssertEqual(conv(1, "mi", "m")!, 1609.344, accuracy: 1e-6)
        XCTAssertEqual(conv(100, "cm", "m")!, 1, accuracy: 1e-9)
    }

    func testMass() {
        XCTAssertEqual(conv(1, "kg", "g")!, 1000, accuracy: 1e-9)
        XCTAssertEqual(conv(1, "lb", "g")!, 453.59237, accuracy: 1e-6)
        XCTAssertEqual(conv(16, "oz", "lb")!, 1, accuracy: 1e-6)
    }

    func testTemperature() {
        XCTAssertEqual(conv(0, "c", "f")!, 32, accuracy: 1e-9)
        XCTAssertEqual(conv(100, "c", "f")!, 212, accuracy: 1e-9)
        XCTAssertEqual(conv(0, "c", "k")!, 273.15, accuracy: 1e-9)
        XCTAssertEqual(conv(212, "f", "c")!, 100, accuracy: 1e-9)
        XCTAssertEqual(conv(273.15, "k", "c")!, 0, accuracy: 1e-9)
    }

    func testAliasesAndPlurals() {
        XCTAssertEqual(conv(1, "kilometers", "meters")!, 1000, accuracy: 1e-9)
        XCTAssertEqual(conv(0, "celsius", "fahrenheit")!, 32, accuracy: 1e-9)
        XCTAssertEqual(conv(2, "pounds", "ounces")!, 32, accuracy: 1e-6)
        XCTAssertEqual(UnitConvert.canonical("Feet"), "ft")
    }

    func testRejectsCrossDimensionAndUnknown() {
        XCTAssertNil(conv(1, "m", "kg"), "length → mass is invalid")
        XCTAssertNil(conv(1, "c", "m"), "temp → length is invalid")
        XCTAssertNil(conv(1, "m", "lightyear"), "unknown unit")
        XCTAssertNil(UnitConvert.canonical("blarg"))
    }
}
