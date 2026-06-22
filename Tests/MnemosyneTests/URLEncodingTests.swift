import XCTest
@testable import Mnemosyne

final class URLEncodingTests: XCTestCase {

    func testEncodesReservedAndSpaces() {
        XCTAssertEqual(URLEncoding.encode("hello world & foo=bar"),
                       "hello%20world%20%26%20foo%3Dbar")
    }

    func testLeavesUnreservedUntouched() {
        XCTAssertEqual(URLEncoding.encode("a-b_c.d~e"), "a-b_c.d~e")
    }

    func testDecode() {
        XCTAssertEqual(URLEncoding.decode("hello%20world"), "hello world")
        XCTAssertEqual(URLEncoding.decode("a%26b"), "a&b")
    }

    func testRoundTripAndMalformed() {
        let original = "q = a/b?c#d e"
        XCTAssertEqual(URLEncoding.decode(URLEncoding.encode(original)), original)
        XCTAssertNil(URLEncoding.decode("%ZZ"))   // malformed escape
    }
}
