import XCTest
@testable import Mnemosyne

final class LuhnTests: XCTestCase {

    func testKnownValidNumbers() {
        XCTAssertTrue(Luhn.isValid("79927398713"))            // classic Luhn example
        XCTAssertTrue(Luhn.isValid("4111 1111 1111 1111"))    // Visa test number, spaces ignored
        XCTAssertTrue(Luhn.isValid("4539-1488-0343-6467"))    // dashes ignored
    }

    func testInvalidNumbers() {
        XCTAssertFalse(Luhn.isValid("79927398710"))           // last digit changed
        XCTAssertFalse(Luhn.isValid("1234 5678 9012 3456"))
    }

    func testTooShortOrNoDigits() {
        XCTAssertFalse(Luhn.isValid("7"))
        XCTAssertFalse(Luhn.isValid(""))
        XCTAssertFalse(Luhn.isValid("no digits"))
    }
}
