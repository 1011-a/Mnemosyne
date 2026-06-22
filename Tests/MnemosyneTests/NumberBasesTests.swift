import XCTest
@testable import Mnemosyne

final class NumberBasesTests: XCTestCase {

    func testParsesEachInputBase() {
        XCTAssertEqual(NumberBases.parse("255"), 255)
        XCTAssertEqual(NumberBases.parse("0xff"), 255)
        XCTAssertEqual(NumberBases.parse("0b1010"), 10)
        XCTAssertEqual(NumberBases.parse("0o17"), 15)
        XCTAssertEqual(NumberBases.parse("-10"), -10)
        XCTAssertNil(NumberBases.parse("zzz"))
        XCTAssertNil(NumberBases.parse("0xzz"))
    }

    func testDescribesAllBases() {
        let d = NumberBases.describe("255")
        XCTAssertNotNil(d)
        XCTAssertTrue(d!.contains("decimal 255"), d ?? "")
        XCTAssertTrue(d!.contains("hex 0xff"), d ?? "")
        XCTAssertTrue(d!.contains("binary 0b11111111"), d ?? "")
        XCTAssertTrue(d!.contains("octal 0o377"), d ?? "")
    }

    func testHexInputDescribesToDecimal() {
        XCTAssertTrue(NumberBases.describe("0xff")!.contains("decimal 255"))
    }

    func testNegativeKeepsSignedPrefix() {
        XCTAssertTrue(NumberBases.describe("-10")!.contains("hex -0xa"))
    }
}
