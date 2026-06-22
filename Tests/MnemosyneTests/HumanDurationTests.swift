import XCTest
@testable import Mnemosyne

final class HumanDurationTests: XCTestCase {

    func testHumanizeShowsNonZeroParts() {
        XCTAssertEqual(HumanDuration.humanize(0), "0s")
        XCTAssertEqual(HumanDuration.humanize(90), "1m 30s")
        XCTAssertEqual(HumanDuration.humanize(3661), "1h 1m 1s")
        XCTAssertEqual(HumanDuration.humanize(90000), "1d 1h")     // 0m 0s omitted
        XCTAssertEqual(HumanDuration.humanize(-65), "-1m 5s")
    }

    func testParsesUnitForm() {
        XCTAssertEqual(HumanDuration.parse("1h 30m"), 5400)
        XCTAssertEqual(HumanDuration.parse("90m"), 5400)
        XCTAssertEqual(HumanDuration.parse("2d"), 172800)
    }

    func testParsesColonForm() {
        XCTAssertEqual(HumanDuration.parse("1:30"), 90)
        XCTAssertEqual(HumanDuration.parse("1:01:01"), 3661)
    }

    func testInvalidIsNilAndRoundTrips() {
        XCTAssertNil(HumanDuration.parse("garbage"))
        XCTAssertNil(HumanDuration.parse(""))
        // humanize → parse round trip for a representative value.
        XCTAssertEqual(HumanDuration.parse(HumanDuration.humanize(3661)), 3661)
    }
}
