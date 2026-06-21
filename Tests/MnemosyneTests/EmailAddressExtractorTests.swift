import XCTest
@testable import Mnemosyne

final class EmailAddressExtractorTests: XCTestCase {

    func testExtractsDistinctLowercasedInOrder() {
        let text = "Contact Alice@Example.com or bob@work.org; also ALICE@example.com again."
        XCTAssertEqual(EmailAddressExtractor.extract(text), ["alice@example.com", "bob@work.org"])
    }

    func testStripsTrailingPunctuation() {
        XCTAssertEqual(EmailAddressExtractor.extract("Reach me at sam@team.io."), ["sam@team.io"])
        XCTAssertEqual(EmailAddressExtractor.extract("emails: a@b.co, c@d.net;"), ["a@b.co", "c@d.net"])
    }

    func testIgnoresNonEmails() {
        XCTAssertTrue(EmailAddressExtractor.extract("no addresses here, just @handles and plain text").isEmpty)
        XCTAssertTrue(EmailAddressExtractor.extract("").isEmpty)
    }

    func testRespectsMax() {
        let text = (0..<10).map { "u\($0)@x.com" }.joined(separator: " ")
        XCTAssertEqual(EmailAddressExtractor.extract(text, max: 3).count, 3)
    }
}
