import XCTest
@testable import Mnemosyne

final class CaseConverterTests: XCTestCase {

    func testUpperAndLower() {
        XCTAssertEqual(CaseConverter.convert("Hello", mode: "upper"), "HELLO")
        XCTAssertEqual(CaseConverter.convert("Hello", mode: "lower"), "hello")
    }

    func testTitleCaseNormalizesMixedInput() {
        XCTAssertEqual(CaseConverter.convert("hello WORLD foo", mode: "title"), "Hello World Foo")
    }

    func testSentenceCaseCapitalizesEachSentence() {
        XCTAssertEqual(CaseConverter.sentenceCase("hello. how ARE you?"), "Hello. How are you?")
        XCTAssertEqual(CaseConverter.sentenceCase("one! two. three"), "One! Two. Three")
    }

    func testUnknownModeIsNil() {
        XCTAssertNil(CaseConverter.convert("x", mode: "camel"))
        XCTAssertEqual(CaseConverter.convert("x", mode: "UPPER"), "X")   // mode match is case-insensitive
    }
}
