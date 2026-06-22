import XCTest
@testable import Mnemosyne

final class PasswordStrengthTests: XCTestCase {

    func testShortLowercaseIsVeryWeak() {
        let r = PasswordStrength.evaluate("abc")
        XCTAssertEqual(r?.poolSize, 26)
        XCTAssertEqual(r?.label, "very weak")
    }

    func testPoolGrowsWithCharacterClasses() {
        let r = PasswordStrength.evaluate("Ab1!")
        XCTAssertEqual(r?.poolSize, 26 + 26 + 10 + 32)   // all four classes
    }

    func testLongerMixedIsStronger() {
        let weak = PasswordStrength.evaluate("Ab1!")!.bits
        let strong = PasswordStrength.evaluate("Ab1!Ab1!Ab1!Ab1!")!.bits
        XCTAssertGreaterThan(strong, weak)
        XCTAssertEqual(PasswordStrength.evaluate("CorrectHorseBatteryStaple1!")?.label, "very strong")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(PasswordStrength.evaluate(""))
    }
}
