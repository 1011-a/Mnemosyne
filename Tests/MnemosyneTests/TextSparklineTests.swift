import XCTest
@testable import Mnemosyne

final class TextSparklineTests: XCTestCase {

    func testMonotonicSeriesMapsAcrossAllBlocks() {
        XCTAssertEqual(TextSparkline.spark([1, 2, 3, 4, 5, 6, 7, 8]), "▁▂▃▄▅▆▇█")
    }

    func testFlatSeriesUsesMidBlock() {
        XCTAssertEqual(TextSparkline.spark([5, 5, 5]), "▄▄▄")
    }

    func testEndpointsHitLowestAndHighest() {
        let s = TextSparkline.spark([0, 50, 100])
        XCTAssertEqual(s.first, "▁")
        XCTAssertEqual(s.last, "█")
        XCTAssertEqual(s.count, 3)
    }

    func testRenderIncludesRangeAndEmptyIsNil() {
        let r = TextSparkline.render("3, 5, 4, 8, 6, 9")
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("3→9 over 6 points"), r ?? "")
        XCTAssertNil(TextSparkline.render("nope"))
        XCTAssertNil(TextSparkline.render(""))
    }
}
