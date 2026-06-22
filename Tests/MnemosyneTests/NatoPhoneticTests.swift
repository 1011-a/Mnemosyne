import XCTest
@testable import Mnemosyne

final class NatoPhoneticTests: XCTestCase {

    func testSpellsLettersCaseInsensitive() {
        XCTAssertEqual(NatoPhonetic.spell("Cat"), "Charlie Alfa Tango")
    }

    func testSpellsDigits() {
        XCTAssertEqual(NatoPhonetic.spell("A1"), "Alfa One")
    }

    func testSpaceAndUnknownPassThrough() {
        XCTAssertEqual(NatoPhonetic.spell("A B"), "Alfa (space) Bravo")
        XCTAssertEqual(NatoPhonetic.spell("a-b"), "Alfa - Bravo")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(NatoPhonetic.spell(""))
    }
}
