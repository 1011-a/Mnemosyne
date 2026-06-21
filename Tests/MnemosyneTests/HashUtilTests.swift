import XCTest
@testable import Mnemosyne

final class HashUtilTests: XCTestCase {

    func testKnownSha256Vectors() {
        // Standard NIST test vectors.
        XCTAssertEqual(HashUtil.sha256(""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(HashUtil.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testShortFingerprintIsFirstEightHex() {
        XCTAssertEqual(HashUtil.short("abc"), "ba7816bf")
        XCTAssertEqual(HashUtil.short("abc").count, 8)
    }

    func testDeterministicAndSensitiveToChange() {
        XCTAssertEqual(HashUtil.sha256("hello"), HashUtil.sha256("hello"))
        XCTAssertNotEqual(HashUtil.sha256("hello"), HashUtil.sha256("hello "))  // trailing space matters
    }

    func testHexIsLowercaseAnd64Chars() {
        let h = HashUtil.sha256("Mnemosyne")
        XCTAssertEqual(h.count, 64)
        XCTAssertEqual(h, h.lowercased())
    }
}
