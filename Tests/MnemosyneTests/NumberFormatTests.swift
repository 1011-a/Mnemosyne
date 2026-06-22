import XCTest
@testable import Mnemosyne

final class NumberFormatTests: XCTestCase {

    func testGroupsThousands() {
        XCTAssertEqual(NumberFormat.grouped("1234567"), "1,234,567")
        XCTAssertEqual(NumberFormat.grouped("1000"), "1,000")
        XCTAssertEqual(NumberFormat.grouped("999"), "999")
    }

    func testPreservesSignAndDecimals() {
        XCTAssertEqual(NumberFormat.grouped("-1234567.89"), "-1,234,567.89")
        XCTAssertEqual(NumberFormat.grouped("1234.5"), "1,234.5")
    }

    func testRegroupsExistingCommas() {
        XCTAssertEqual(NumberFormat.grouped("1,2,3,4"), "1,234")
    }

    func testInvalidIsNil() {
        XCTAssertNil(NumberFormat.grouped("abc"))
        XCTAssertNil(NumberFormat.grouped("12.3.4"))
    }
}
