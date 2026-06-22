import XCTest
@testable import Mnemosyne

final class URLParserTests: XCTestCase {

    func testParsesFullURLWithQueryAndFragment() {
        let p = URLParser.parse("https://example.com/path?a=1&b=two#sec")
        XCTAssertEqual(p?.scheme, "https")
        XCTAssertEqual(p?.host, "example.com")
        XCTAssertEqual(p?.path, "/path")
        XCTAssertEqual(p?.params.map(\.key), ["a", "b"])
        XCTAssertEqual(p?.params.map(\.value), ["1", "two"])
        XCTAssertEqual(p?.fragment, "sec")
    }

    func testDecodesPercentEncodedParams() {
        let p = URLParser.parse("https://x.test/s?q=hello%20world")
        XCTAssertEqual(p?.params.first?.value, "hello world")
    }

    func testAddsSchemeForBareHost() {
        let p = URLParser.parse("example.com/page?ref=1")
        XCTAssertEqual(p?.host, "example.com")
        XCTAssertEqual(p?.path, "/page")
        XCTAssertEqual(p?.params.first.map { "\($0.key)=\($0.value)" }, "ref=1")
    }

    func testInvalidIsNilAndSummaryListsParts() {
        XCTAssertNil(URLParser.parse("not a url"))
        XCTAssertNil(URLParser.summary(""))
        let s = URLParser.summary("https://example.com/p?utm_source=news")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("host: example.com"), s ?? "")
        XCTAssertTrue(s!.contains("utm_source = news"), s ?? "")
    }
}
