import XCTest
@testable import Mnemosyne

final class TipCalculatorTests: XCTestCase {

    func testTipAndSplit() {
        let r = TipCalculator.compute(bill: 100, percent: 20, people: 4)
        XCTAssertEqual(r, TipCalculator.Result(tip: 20, total: 120, perPerson: 30))
    }

    func testDefaultsToOnePerson() {
        let r = TipCalculator.compute(bill: 50, percent: 18)
        XCTAssertEqual(r?.tip ?? 0, 9, accuracy: 1e-9)
        XCTAssertEqual(r?.perPerson ?? 0, 59, accuracy: 1e-9)
    }

    func testZeroPercent() {
        let r = TipCalculator.compute(bill: 80, percent: 0, people: 2)
        XCTAssertEqual(r?.tip, 0)
        XCTAssertEqual(r?.perPerson, 40)
    }

    func testInvalidInputsReturnNil() {
        XCTAssertNil(TipCalculator.compute(bill: -1, percent: 10))
        XCTAssertNil(TipCalculator.compute(bill: 10, percent: -5))
        XCTAssertNil(TipCalculator.compute(bill: 10, percent: 10, people: 0))
    }
}
