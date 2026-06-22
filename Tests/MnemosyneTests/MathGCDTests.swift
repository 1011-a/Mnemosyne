import XCTest
@testable import Mnemosyne

final class MathGCDTests: XCTestCase {

    func testGCD() {
        XCTAssertEqual(MathGCD.gcd(12, 18), 6)
        XCTAssertEqual(MathGCD.gcd(7, 5), 1)        // coprime
        XCTAssertEqual(MathGCD.gcd(0, 5), 5)
        XCTAssertEqual(MathGCD.gcd(0, 0), 0)
        XCTAssertEqual(MathGCD.gcd(-12, 18), 6)     // negatives via abs
    }

    func testLCM() {
        XCTAssertEqual(MathGCD.lcm(12, 18), 36)
        XCTAssertEqual(MathGCD.lcm(7, 5), 35)
        XCTAssertEqual(MathGCD.lcm(0, 5), 0)        // lcm with 0 is 0
        XCTAssertEqual(MathGCD.lcm(-4, 6), 12)
    }

    func testRelation() {
        // gcd(a,b) * lcm(a,b) == |a*b| for nonzero inputs.
        let a = 24, b = 36
        XCTAssertEqual(MathGCD.gcd(a, b) * MathGCD.lcm(a, b), abs(a * b))
    }
}
