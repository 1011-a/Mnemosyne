import XCTest
@testable import Mnemosyne

final class AnagramTests: XCTestCase {

    func testClassicAnagramIgnoringCaseAndSpaces() {
        XCTAssertTrue(Anagram.isAnagram("Listen", "Silent"))
        XCTAssertTrue(Anagram.isAnagram("Dormitory", "Dirty room"))
    }

    func testNonAnagram() {
        XCTAssertFalse(Anagram.isAnagram("hello", "world"))
        XCTAssertFalse(Anagram.isAnagram("abc", "abcd"))   // different lengths
    }

    func testPunctuationAndDigitsHandled() {
        XCTAssertTrue(Anagram.isAnagram("A1!", "1a"))
        XCTAssertEqual(Anagram.signature("Silent!"), "eilnst")
    }

    func testEmptyOrPunctuationOnlyIsNotAnagram() {
        XCTAssertFalse(Anagram.isAnagram("", ""))
        XCTAssertFalse(Anagram.isAnagram("!!!", "???"))
    }
}
