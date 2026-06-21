import XCTest
@testable import Mnemosyne

final class CalculatorTests: XCTestCase {

    private func eval(_ s: String) -> Double? { Calculator.eval(s) }

    func testBasicArithmeticAndPrecedence() {
        XCTAssertEqual(eval("1 + 2 * 3"), 7, "× before +")
        XCTAssertEqual(eval("(1 + 2) * 3"), 9, "parentheses override")
        XCTAssertEqual(eval("10 - 2 - 3"), 5, "left-assoc subtraction")
        XCTAssertEqual(eval("20 / 4 / 5"), 1, "left-assoc division")
        XCTAssertEqual(eval("2 + 3 * 4 - 5"), 9)
    }

    func testPowerIsRightAssociative() {
        XCTAssertEqual(eval("2 ^ 3"), 8)
        XCTAssertEqual(eval("2 ^ 3 ^ 2"), 512, "right-assoc: 2^(3^2)=2^9")
        XCTAssertEqual(eval("(2 ^ 3) ^ 2"), 64)
    }

    func testUnaryAndModulo() {
        XCTAssertEqual(eval("-5 + 3"), -2)
        XCTAssertEqual(eval("-(2 + 3)"), -5)
        XCTAssertEqual(eval("--4"), 4, "double negation")
        XCTAssertEqual(eval("10 % 3"), 1)
        XCTAssertEqual(eval("2 * -3"), -6)
    }

    func testDecimals() {
        XCTAssertEqual(eval("0.5 + 0.25"), 0.75)
        XCTAssertEqual(eval("3.0 * 2"), 6)
    }

    func testInvalidReturnsNil() {
        XCTAssertNil(eval("1 +"), "trailing operator")
        XCTAssertNil(eval("(1 + 2"), "unbalanced paren")
        XCTAssertNil(eval("1 + abc"), "identifiers rejected")
        XCTAssertNil(eval("5 / 0"), "divide by zero")
        XCTAssertNil(eval("7 % 0"), "modulo by zero")
        XCTAssertNil(eval(""), "empty")
        XCTAssertNil(eval("2 3"), "two numbers, no operator")
    }

    func testFormatTrimsIntegerZeros() {
        XCTAssertEqual(Calculator.format(6.0), "6")
        XCTAssertEqual(Calculator.format(-2.0), "-2")
        XCTAssertEqual(Calculator.format(0.75), "0.75")
    }
}
