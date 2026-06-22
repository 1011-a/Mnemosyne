import XCTest
@testable import Mnemosyne

final class MorseCodeTests: XCTestCase {

    func testEncodeWordWithSpacing() {
        XCTAssertEqual(MorseCode.encode("SOS"), "... --- ...")
    }

    func testEncodeMultipleWordsUsesSlash() {
        XCTAssertEqual(MorseCode.encode("HI ME"), ".... .. / -- .")
    }

    func testDecodeIsInverseOfEncode() {
        let text = "HELLO WORLD"
        let morse = MorseCode.encode(text)!
        XCTAssertEqual(MorseCode.decode(morse), text)
    }

    func testDecodeDigitsAndUnknown() {
        XCTAssertEqual(MorseCode.decode(".---- ..---"), "12")
        XCTAssertEqual(MorseCode.decode("...... "), "?")   // not a valid code → ?
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(MorseCode.encode(""))
        XCTAssertNil(MorseCode.decode("   "))
    }
}
