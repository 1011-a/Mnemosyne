import XCTest
@testable import Mnemosyne

final class CaseStyleTests: XCTestCase {

    func testWordSplittingAcrossStyles() {
        XCTAssertEqual(CaseStyle.words("helloWorld"), ["hello", "world"])
        XCTAssertEqual(CaseStyle.words("hello_world"), ["hello", "world"])
        XCTAssertEqual(CaseStyle.words("HelloWorld"), ["hello", "world"])
        XCTAssertEqual(CaseStyle.words("my-variable name"), ["my", "variable", "name"])
    }

    func testConversions() {
        XCTAssertEqual(CaseStyle.toSnake("helloWorld"), "hello_world")
        XCTAssertEqual(CaseStyle.toCamel("hello_world"), "helloWorld")
        XCTAssertEqual(CaseStyle.toKebab("HelloWorld"), "hello-world")
        XCTAssertEqual(CaseStyle.toPascal("my-variable name"), "MyVariableName")
    }

    func testRoundTripAndUnknownStyle() {
        let snake = CaseStyle.toSnake("SomeLongName")
        XCTAssertEqual(CaseStyle.toPascal(snake), "SomeLongName")
        XCTAssertNil(CaseStyle.convert("x", style: "screaming"))
    }
}
