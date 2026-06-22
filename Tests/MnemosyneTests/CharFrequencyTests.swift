import XCTest
@testable import Mnemosyne

final class CharFrequencyTests: XCTestCase {

    func testCountsCaseInsensitivelyAndSortsByCount() {
        let rows = CharFrequency.analyze("aAaB b!")
        // a:3, b:2 → a first.
        XCTAssertEqual(rows.first?.letter, "a")
        XCTAssertEqual(rows.first?.count, 3)
        XCTAssertEqual(rows[1].letter, "b")
        XCTAssertEqual(rows[1].count, 2)
    }

    func testPercentagesSumToHundred() {
        let rows = CharFrequency.analyze("abcd")
        let sum = rows.reduce(0.0) { $0 + $1.percent }
        XCTAssertEqual(sum, 100.0, accuracy: 1e-9)
        XCTAssertEqual(rows.count, 4)
    }

    func testTiesBreakAlphabetically() {
        let rows = CharFrequency.analyze("zyx")   // all count 1
        XCTAssertEqual(rows.map(\.letter), ["x", "y", "z"])
    }

    func testNoLettersGivesEmpty() {
        XCTAssertTrue(CharFrequency.analyze("123 !!! ...").isEmpty)
        XCTAssertEqual(CharFrequency.table(CharFrequency.analyze("123")), "")
    }

    func testTableFormatsAndLimits() {
        let table = CharFrequency.table(CharFrequency.analyze("aaab"), limit: 1)
        XCTAssertEqual(table, "A  3  (75.0%)")
    }
}
