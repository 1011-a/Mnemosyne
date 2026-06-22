import XCTest
@testable import Mnemosyne

final class NumberWordsTests: XCTestCase {

    func testSmallNumbers() {
        XCTAssertEqual(NumberWords.spell(0), "zero")
        XCTAssertEqual(NumberWords.spell(7), "seven")
        XCTAssertEqual(NumberWords.spell(19), "nineteen")
        XCTAssertEqual(NumberWords.spell(23), "twenty-three")
        XCTAssertEqual(NumberWords.spell(40), "forty")
    }

    func testHundredsAndThousands() {
        XCTAssertEqual(NumberWords.spell(100), "one hundred")
        XCTAssertEqual(NumberWords.spell(305), "three hundred five")
        XCTAssertEqual(NumberWords.spell(1234), "one thousand two hundred thirty-four")
        XCTAssertEqual(NumberWords.spell(1000000), "one million")
    }

    func testNegative() {
        XCTAssertEqual(NumberWords.spell(-5), "negative five")
        XCTAssertEqual(NumberWords.spell(-21), "negative twenty-one")
    }

    func testZeroGroupsSkipped() {
        XCTAssertEqual(NumberWords.spell(1000005), "one million five")   // no "zero thousand"
    }
}
