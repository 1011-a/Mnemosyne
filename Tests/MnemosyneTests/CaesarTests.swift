import XCTest
@testable import Mnemosyne

final class CaesarTests: XCTestCase {

    func testBasicShiftAndWrap() {
        XCTAssertEqual(Caesar.shift("abc", by: 1), "bcd")
        XCTAssertEqual(Caesar.shift("XYZ", by: 3), "ABC")     // wraps within uppercase
        XCTAssertEqual(Caesar.shift("xyz", by: 3), "abc")
    }

    func testRot13IsSelfInverse() {
        XCTAssertEqual(Caesar.shift("Hello, World!", by: 13), "Uryyb, Jbeyq!")
        XCTAssertEqual(Caesar.shift(Caesar.shift("Hello, World!", by: 13), by: 13), "Hello, World!")
    }

    func testPreservesNonLetters() {
        XCTAssertEqual(Caesar.shift("a1 b2!", by: 1), "b1 c2!")
    }

    func testNegativeAndLargeShiftsNormalize() {
        XCTAssertEqual(Caesar.shift("bcd", by: -1), "abc")
        XCTAssertEqual(Caesar.shift("abc", by: 27), "bcd")    // 27 ≡ 1 mod 26
    }
}
