import XCTest
@testable import Mnemosyne

final class RomanTests: XCTestCase {

    func testToRomanIncludingSubtractiveForms() {
        XCTAssertEqual(Roman.toRoman(4), "IV")
        XCTAssertEqual(Roman.toRoman(9), "IX")
        XCTAssertEqual(Roman.toRoman(40), "XL")
        XCTAssertEqual(Roman.toRoman(1994), "MCMXCIV")
        XCTAssertEqual(Roman.toRoman(3999), "MMMCMXCIX")
        XCTAssertNil(Roman.toRoman(0))
        XCTAssertNil(Roman.toRoman(4000))
    }

    func testFromRomanCanonicalOnly() {
        XCTAssertEqual(Roman.fromRoman("IV"), 4)
        XCTAssertEqual(Roman.fromRoman("mcmxciv"), 1994)   // case-insensitive
        XCTAssertNil(Roman.fromRoman("IIII"))              // non-canonical rejected
        XCTAssertNil(Roman.fromRoman("ABC"))               // invalid characters
    }

    func testConvertAutoDetectsDirection() {
        XCTAssertEqual(Roman.convert("1994"), "MCMXCIV")
        XCTAssertEqual(Roman.convert("IV"), "4")
        XCTAssertNil(Roman.convert("nope"))
        XCTAssertNil(Roman.convert("4000"))
    }
}
