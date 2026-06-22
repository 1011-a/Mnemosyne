import XCTest
@testable import Mnemosyne

final class AcronymMakerTests: XCTestCase {

    func testBasicAcronyms() {
        XCTAssertEqual(AcronymMaker.make("Portable Document Format"), "PDF")
        XCTAssertEqual(AcronymMaker.make("As Soon As Possible"), "ASAP")
        XCTAssertEqual(AcronymMaker.make("hyper text markup language"), "HTML")
    }

    func testSkipMinorWords() {
        XCTAssertEqual(AcronymMaker.make("the lord of the rings", skipMinor: true), "LR")
        XCTAssertEqual(AcronymMaker.make("the lord of the rings", skipMinor: false), "TLOTR")
    }

    func testHandlesHyphensAndLeadingNonLetters() {
        XCTAssertEqual(AcronymMaker.make("self-contained underwater breathing apparatus"), "SCUBA")
        XCTAssertEqual(AcronymMaker.make("3D model viewer"), "DMV")  // first letter of "3D" is D
    }

    func testEmpty() {
        XCTAssertEqual(AcronymMaker.make(""), "")
        XCTAssertEqual(AcronymMaker.make("123 456"), "")
    }
}
