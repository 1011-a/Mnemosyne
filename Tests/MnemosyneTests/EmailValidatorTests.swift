import XCTest
@testable import Mnemosyne

final class EmailValidatorTests: XCTestCase {

    func testValidAddresses() {
        XCTAssertTrue(EmailValidator.isValid("a@b.com"))
        XCTAssertTrue(EmailValidator.isValid("user.name+tag@example.co.uk"))
        XCTAssertTrue(EmailValidator.isValid("  trimmed@x.io  "))   // surrounding spaces trimmed
    }

    func testInvalidAddresses() {
        XCTAssertFalse(EmailValidator.isValid("no-at-sign"))
        XCTAssertFalse(EmailValidator.isValid("a@b"))               // no TLD
        XCTAssertFalse(EmailValidator.isValid("a@@b.com"))
        XCTAssertFalse(EmailValidator.isValid("spaces in@b.com"))   // whole string must match
        XCTAssertFalse(EmailValidator.isValid(""))
    }

    func testWholeStringMustMatch() {
        XCTAssertFalse(EmailValidator.isValid("prefix a@b.com suffix"))
    }
}
