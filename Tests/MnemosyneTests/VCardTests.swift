import XCTest
@testable import Mnemosyne

final class VCardTests: XCTestCase {

    func testParsesContactFields() {
        let text = VCardExtractor.parse("""
        BEGIN:VCARD
        VERSION:3.0
        FN:Jane Smith
        N:Smith;Jane;;;
        ORG:Acme Corp
        TITLE:Engineer
        EMAIL;TYPE=WORK:jane@acme.com
        TEL;TYPE=CELL:+1-555-0100
        NOTE:Met at WWDC
        END:VCARD
        """)
        XCTAssertTrue(text.contains("Jane Smith"))
        XCTAssertTrue(text.contains("Engineer at Acme Corp"))
        XCTAssertTrue(text.contains("jane@acme.com"))
        XCTAssertTrue(text.contains("+1-555-0100"))
        XCTAssertTrue(text.contains("Met at WWDC"))
    }

    func testStructuredNameWhenNoFN() {
        let text = VCardExtractor.parse("""
        BEGIN:VCARD
        N:Doe;John;;;
        EMAIL:john@example.com
        END:VCARD
        """)
        XCTAssertTrue(text.hasPrefix("John Doe"), "should derive a name from N when FN is absent: \(text)")
    }

    func testMultipleContactsSeparated() {
        let text = VCardExtractor.parse("""
        BEGIN:VCARD
        FN:Alice
        END:VCARD
        BEGIN:VCARD
        FN:Bob
        END:VCARD
        """)
        let cards = text.components(separatedBy: "\n\n")
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(text.contains("Alice") && text.contains("Bob"))
    }

    func testLineUnfolding() {
        // RFC 6350 folding: a continuation line begins with a space.
        let text = VCardExtractor.parse("""
        BEGIN:VCARD
        FN:X
        NOTE:Met at the conf
         erence last year
        END:VCARD
        """)
        XCTAssertTrue(text.contains("conference last year"), "folded lines must rejoin: \(text)")
    }

    func testEscapeSequences() {
        let text = VCardExtractor.parse("""
        BEGIN:VCARD
        FN:Y
        NOTE:Line1\\nLine2\\, more
        END:VCARD
        """)
        XCTAssertTrue(text.contains("Line1 Line2, more"), "got: \(text)")
    }

    func testNonVCardYieldsEmpty() {
        XCTAssertTrue(VCardExtractor.parse("just some text\nno vcard here").isEmpty)
    }

    func testTypeDetectorMapsVCardToContact() {
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/jane.vcf")), .contact)
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/team.vcard")), .contact)
    }
}
