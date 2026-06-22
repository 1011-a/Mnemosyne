import XCTest
@testable import Mnemosyne

final class TempConvertTests: XCTestCase {

    func testCelsiusFahrenheit() {
        XCTAssertEqual(TempConvert.convert(100, from: "C", to: "F"), 212)
        XCTAssertEqual(TempConvert.convert(0, from: "C", to: "F"), 32)
        XCTAssertEqual(TempConvert.convert(32, from: "F", to: "C"), 0)
        XCTAssertEqual(TempConvert.convert(37, from: "C", to: "F")!, 98.6, accuracy: 1e-9)
    }

    func testKelvin() {
        XCTAssertEqual(TempConvert.convert(0, from: "C", to: "K")!, 273.15, accuracy: 1e-9)
        XCTAssertEqual(TempConvert.convert(300, from: "K", to: "C")!, 26.85, accuracy: 1e-9)
        XCTAssertEqual(TempConvert.convert(212, from: "F", to: "K")!, 373.15, accuracy: 1e-9)
    }

    func testSameUnitAndFullWordsAndUnknown() {
        XCTAssertEqual(TempConvert.convert(50, from: "Celsius", to: "celsius"), 50)
        XCTAssertNil(TempConvert.convert(1, from: "X", to: "C"))
        XCTAssertNil(TempConvert.convert(1, from: "C", to: "Z"))
    }
}
