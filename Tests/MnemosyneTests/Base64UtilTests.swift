import XCTest
@testable import Mnemosyne

final class Base64UtilTests: XCTestCase {

    func testEncodeKnownValue() {
        XCTAssertEqual(Base64Util.encode("hello"), "aGVsbG8=")
    }

    func testDecodeKnownValue() {
        XCTAssertEqual(Base64Util.decode("aGVsbG8="), "hello")
    }

    func testRoundTripPreservesUnicode() {
        let original = "café — naïve 🚀"
        XCTAssertEqual(Base64Util.decode(Base64Util.encode(original)), original)
    }

    func testDecodeInvalidAndNonUTF8ReturnNil() {
        XCTAssertNil(Base64Util.decode("!!!not base64!!!"))   // not decodable
        XCTAssertNil(Base64Util.decode("////"))               // valid base64 (0xFF…) but not UTF-8
    }
}
