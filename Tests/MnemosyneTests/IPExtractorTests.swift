import XCTest
@testable import Mnemosyne

final class IPExtractorTests: XCTestCase {

    func testExtractsValidIPv4() {
        let ips = IPExtractor.extract("Server 192.168.1.1 talked to 10.0.0.5 then dropped.")
        XCTAssertEqual(ips, ["192.168.1.1", "10.0.0.5"])
    }

    func testRejectsOutOfRangeOctets() {
        XCTAssertTrue(IPExtractor.extract("bad 999.1.1.1 and 256.0.0.1").isEmpty)
        XCTAssertEqual(IPExtractor.extract("edge 255.255.255.0 ok"), ["255.255.255.0"])
    }

    func testDedupes() {
        XCTAssertEqual(IPExtractor.extract("8.8.8.8 and again 8.8.8.8"), ["8.8.8.8"])
    }

    func testSummaryAndEmpty() {
        let s = IPExtractor.summary("ping 1.2.3.4")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("1 IPv4 address"), s ?? "")
        XCTAssertTrue(s!.contains("1.2.3.4"), s ?? "")
        XCTAssertNil(IPExtractor.summary("no addresses here"))
    }
}
