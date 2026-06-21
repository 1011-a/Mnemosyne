import XCTest
@testable import Mnemosyne

final class ContactRollupTests: XCTestCase {

    func testGroupsAllThreeSections() {
        let out = ContactRollup.format(people: ["Ada Lovelace"],
                                       emails: ["ada@example.com"],
                                       phones: ["+1 415-555-2671"])
        XCTAssertEqual(out, """
        People: Ada Lovelace
        Emails: ada@example.com
        Phones: +1 415-555-2671
        """)
    }

    func testOmitsEmptySections() {
        let out = ContactRollup.format(people: [], emails: ["a@b.com", "c@d.com"], phones: [])
        XCTAssertEqual(out, "Emails: a@b.com, c@d.com", "only non-empty sections appear")
    }

    func testDedupesCaseInsensitivelyPreservingFirstSpelling() {
        let out = ContactRollup.format(people: ["Ada", "ada", "Grace"], emails: [], phones: [])
        XCTAssertEqual(out, "People: Ada, Grace", "duplicate collapsed, first spelling kept")
    }

    func testNilWhenNothingFound() {
        XCTAssertNil(ContactRollup.format(people: [], emails: [], phones: []))
        XCTAssertNil(ContactRollup.format(people: ["  "], emails: [""], phones: []), "blanks don't count")
    }
}
