import XCTest
@testable import Mnemosyne

final class DomainExtractorTests: XCTestCase {

    func testExtractsFromUrlsAndEmails() {
        let d = DomainExtractor.extract("Visit https://example.com/page and email a@test.org today.")
        XCTAssertEqual(d, ["example.com", "test.org"])   // sorted, host only
    }

    func testHandlesSubdomainsAndStripsPath() {
        XCTAssertEqual(DomainExtractor.extract("see http://sub.domain.co.uk/x/y"), ["sub.domain.co.uk"])
    }

    func testDedupesAcrossOccurrences() {
        XCTAssertEqual(DomainExtractor.extract("https://a.com and https://a.com/x"), ["a.com"])
    }

    func testNoneAndSummary() {
        XCTAssertTrue(DomainExtractor.extract("no links or emails here").isEmpty)
        let s = DomainExtractor.summary("mail me at x@y.io")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("y.io"), s ?? "")
        XCTAssertNil(DomainExtractor.summary("plain text"))
    }
}
