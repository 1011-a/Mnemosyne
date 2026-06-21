import XCTest
@testable import Mnemosyne

final class LinkExtractorTests: XCTestCase {

    func testExtractsHttpAndHttpsInOrder() {
        let text = "See https://a.com and http://b.org/page for details."
        XCTAssertEqual(LinkExtractor.extract(text), ["https://a.com", "http://b.org/page"])
    }

    func testStripsTrailingPunctuationAndDedupes() {
        let text = """
        Read https://example.com/path. Also (https://example.com/path) again,
        and https://other.com!
        """
        let links = LinkExtractor.extract(text)
        XCTAssertEqual(links, ["https://example.com/path", "https://other.com"],
                       "trailing . ) , ! trimmed; duplicate collapsed")
    }

    func testIgnoresNonLinks() {
        XCTAssertTrue(LinkExtractor.extract("no links here, just ftp://nope and text").isEmpty,
                      "only http/https are extracted")
    }

    func testRespectsMax() {
        let text = (0..<10).map { "https://s\($0).com" }.joined(separator: " ")
        XCTAssertEqual(LinkExtractor.extract(text, max: 3).count, 3)
    }
}
