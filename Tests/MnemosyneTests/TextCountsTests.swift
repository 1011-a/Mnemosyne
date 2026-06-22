import XCTest
@testable import Mnemosyne

final class TextCountsTests: XCTestCase {

    func testCountsAllDimensions() {
        let c = TextCounts.count("Hello world.\nBye.")
        XCTAssertEqual(c.characters, 17)            // includes the newline + period
        XCTAssertEqual(c.charactersNoSpaces, 15)    // minus the space and newline
        XCTAssertEqual(c.words, 3)
        XCTAssertEqual(c.lines, 2)
        XCTAssertEqual(c.sentences, 2)
    }

    func testSingleSentenceWithoutTerminator() {
        let c = TextCounts.count("no period here")
        XCTAssertEqual(c.sentences, 1)              // content but no terminator → 1
        XCTAssertEqual(c.lines, 1)
        XCTAssertEqual(c.words, 3)
    }

    func testEmptyIsAllZero() {
        XCTAssertEqual(TextCounts.count(""), .init(characters: 0, charactersNoSpaces: 0, words: 0, lines: 0, sentences: 0))
    }

    func testReportFormat() {
        let r = TextCounts.report("One two.")
        XCTAssertTrue(r.contains("Words: 2"), r)
        XCTAssertTrue(r.contains("Sentences: 1"), r)
    }
}
