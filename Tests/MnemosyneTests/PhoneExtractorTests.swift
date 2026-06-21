import XCTest
@testable import Mnemosyne

final class PhoneExtractorTests: XCTestCase {

    func testCommonFormats() {
        let text = "Call +1 (415) 555-2671 or 415-555-2899. London: +44 20 7946 0958."
        let phones = PhoneExtractor.extract(text)
        XCTAssertTrue(phones.contains { $0.filter(\.isNumber) == "14155552671" }, "got: \(phones)")
        XCTAssertTrue(phones.contains { $0.filter(\.isNumber) == "4155552899" }, "got: \(phones)")
        XCTAssertTrue(phones.contains { $0.filter(\.isNumber) == "442079460958" }, "got: \(phones)")
    }

    func testDedupesByDigitsRegardlessOfFormatting() {
        let text = "Reach me at 415-555-2671, or (415) 555-2671, same number."
        let phones = PhoneExtractor.extract(text)
        XCTAssertEqual(phones.filter { $0.filter(\.isNumber) == "4155552671" }.count, 1,
                       "same digits in different formats collapse to one")
    }

    func testDocumentOrderPreserved() {
        let phones = PhoneExtractor.extract("First 212-555-0100 then 310-555-0199.")
        XCTAssertEqual(phones.first?.filter(\.isNumber), "2125550100")
        XCTAssertEqual(phones.last?.filter(\.isNumber), "3105550199")
    }

    func testRejectsNonPhoneShapes() {
        // ISO dates and short/long digit runs must not be mistaken for phone numbers.
        XCTAssertTrue(PhoneExtractor.extract("Due 2026-01-05 per invoice 4471.").isEmpty)
        XCTAssertTrue(PhoneExtractor.extract("Order 12 of 7 items, code 99.").isEmpty)
        XCTAssertTrue(PhoneExtractor.extract("").isEmpty)
    }
}
