import XCTest
@testable import Mnemosyne

final class VigenereCipherTests: XCTestCase {

    func testClassicEncode() {
        // The textbook example: ATTACKATDAWN + LEMON = LXFOPVEFRNHR
        XCTAssertEqual(VigenereCipher.transform("ATTACKATDAWN", key: "LEMON", decode: false),
                       "LXFOPVEFRNHR")
    }

    func testDecodeIsInverseOfEncode() {
        let plain = "Meet me at noon!"
        let enc = VigenereCipher.transform(plain, key: "Secret", decode: false)!
        XCTAssertEqual(VigenereCipher.transform(enc, key: "Secret", decode: true), plain)
    }

    func testCasePreservedAndNonLettersPassThrough() {
        let enc = VigenereCipher.transform("Hi, Bob!", key: "key", decode: false)!
        XCTAssertEqual(enc.count, "Hi, Bob!".count)
        XCTAssertTrue(enc.contains(","))
        XCTAssertTrue(enc.contains("!"))
        XCTAssertTrue(enc.contains(" "))
        // Punctuation doesn't consume a key letter → first letter uses key[0].
        XCTAssertEqual(VigenereCipher.transform("!a", key: "b", decode: false), "!b")
    }

    func testEmptyKeyReturnsNil() {
        XCTAssertNil(VigenereCipher.transform("hello", key: "", decode: false))
        XCTAssertNil(VigenereCipher.transform("hello", key: "123!", decode: false))
    }
}
