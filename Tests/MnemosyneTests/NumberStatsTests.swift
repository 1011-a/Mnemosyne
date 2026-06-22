import XCTest
@testable import Mnemosyne

final class NumberStatsTests: XCTestCase {

    func testComputesAllStatsOnKnownSet() {
        // Classic set: mean 5, population stdev 2.
        let s = NumberStats.compute([2, 4, 4, 4, 5, 5, 7, 9])
        XCTAssertEqual(s?.count, 8)
        XCTAssertEqual(s?.sum, 40)
        XCTAssertEqual(s?.mean, 5)
        XCTAssertEqual(s?.median, 4.5)        // even count → mean of middle two
        XCTAssertEqual(s?.min, 2)
        XCTAssertEqual(s?.max, 9)
        XCTAssertEqual(s?.stdev, 2)
    }

    func testMedianOddAndSingleValue() {
        XCTAssertEqual(NumberStats.compute([3, 1, 2])?.median, 2)   // sorted → middle
        let one = NumberStats.compute([42])
        XCTAssertEqual(one?.median, 42)
        XCTAssertEqual(one?.stdev, 0)
    }

    func testParsesMixedSeparatorsAndSkipsJunk() {
        XCTAssertEqual(NumberStats.parse("12, 19 7\n23"), [12, 19, 7, 23])
        XCTAssertEqual(NumberStats.parse("1, x, 2, foo, 3"), [1, 2, 3])   // junk skipped
    }

    func testReportFormatsAndEmptyIsNil() {
        let r = NumberStats.report("2 4 4 4 5 5 7 9")
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("mean 5"), r ?? "")
        XCTAssertTrue(r!.contains("median 4.5"), r ?? "")
        XCTAssertTrue(r!.contains("range 7"), r ?? "")
        XCTAssertNil(NumberStats.report("no numbers here"))
        XCTAssertNil(NumberStats.report(""))
    }
}
