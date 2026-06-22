import XCTest
@testable import Mnemosyne

final class TimeExtractorTests: XCTestCase {

    func testExtractsColonTimesWithAndWithoutMeridiem() {
        let t = TimeExtractor.extract("Standup at 09:00, review at 3:30 PM.")
        XCTAssertTrue(t.contains("09:00"), "\(t)")
        XCTAssertTrue(t.contains("3:30 PM"), "\(t)")
    }

    func testExtractsBareHourMeridiem() {
        let t = TimeExtractor.extract("Lunch at 12pm, coffee 9 am.")
        XCTAssertTrue(t.contains("12pm"), "\(t)")
        XCTAssertTrue(t.contains("9 am"), "\(t)")
    }

    func testRejectsOutOfRange() {
        XCTAssertTrue(TimeExtractor.extract("bogus 25:99 and 31:00").isEmpty)
        XCTAssertEqual(TimeExtractor.extract("edge 23:59 only"), ["23:59"])
    }

    func testDedupesAndSummaryNil() {
        XCTAssertEqual(TimeExtractor.extract("at 10:00 and again 10:00"), ["10:00"])
        XCTAssertNil(TimeExtractor.summary("no times here"))
    }
}
