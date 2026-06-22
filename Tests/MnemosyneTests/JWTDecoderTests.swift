import XCTest
@testable import Mnemosyne

final class JWTDecoderTests: XCTestCase {

    // The canonical public jwt.io example token (not real credentials).
    private let sample = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    func testDecodesHeaderAndPayload() {
        let d = JWTDecoder.decode(sample)
        XCTAssertNotNil(d)
        XCTAssertTrue(d!.header.contains("HS256"))
        XCTAssertTrue(d!.payload.contains("John Doe"))
        XCTAssertTrue(d!.payload.contains("1234567890"))
    }

    func testMalformedTokensReturnNil() {
        XCTAssertNil(JWTDecoder.decode("only.two"))           // 2 parts
        XCTAssertNil(JWTDecoder.decode("a.b.c.d"))            // 4 parts
        XCTAssertNil(JWTDecoder.decode("!!!.@@@.###"))        // invalid base64url
    }

    func testPrettifyStableOrderAndPassThrough() {
        XCTAssertEqual(JWTDecoder.prettify(#"{"b":1,"a":2}"#), "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
        XCTAssertEqual(JWTDecoder.prettify("not json"), "not json")
    }
}
