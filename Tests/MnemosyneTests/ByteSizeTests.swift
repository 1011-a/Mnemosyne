import XCTest
@testable import Mnemosyne

final class ByteSizeTests: XCTestCase {

    func testHumanizeScalesByThousand() {
        XCTAssertEqual(ByteSize.humanize(500), "500 B")
        XCTAssertEqual(ByteSize.humanize(1000), "1 KB")
        XCTAssertEqual(ByteSize.humanize(1500), "1.5 KB")
        XCTAssertEqual(ByteSize.humanize(1500000), "1.5 MB")
        XCTAssertEqual(ByteSize.humanize(1000000000), "1 GB")
        XCTAssertEqual(ByteSize.humanize(-2000), "-2 KB")
    }

    func testParseWithAndWithoutUnit() {
        XCTAssertEqual(ByteSize.parse("1.5 MB"), 1500000)
        XCTAssertEqual(ByteSize.parse("500 B"), 500)
        XCTAssertEqual(ByteSize.parse("2GB"), 2000000000)
        XCTAssertEqual(ByteSize.parse("1024"), 1024)        // no unit → bytes
    }

    func testInvalidIsNil() {
        XCTAssertNil(ByteSize.parse("big"))
        XCTAssertNil(ByteSize.parse("5 ZB"))                // unknown unit
        XCTAssertNil(ByteSize.parse(""))
    }

    func testRoundTripForRepresentativeValue() {
        XCTAssertEqual(ByteSize.parse(ByteSize.humanize(1500000)), 1500000)
    }
}
