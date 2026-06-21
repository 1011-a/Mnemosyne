import XCTest
@testable import Mnemosyne

final class MoneyExtractorTests: XCTestCase {

    func testParsesSymbolAndCodeForms() {
        let amounts = MoneyExtractor.extract("Lunch $12.50, taxi €8, and 45 USD for parking.")
        XCTAssertTrue(amounts.contains(.init(currency: "USD", value: 12.5)), "\(amounts)")
        XCTAssertTrue(amounts.contains(.init(currency: "EUR", value: 8)), "\(amounts)")
        XCTAssertTrue(amounts.contains(.init(currency: "USD", value: 45)), "\(amounts)")
    }

    func testStripsThousandsSeparators() {
        let amounts = MoneyExtractor.extract("Invoice total: $1,200.50")
        XCTAssertEqual(amounts, [.init(currency: "USD", value: 1200.5)])
    }

    func testOverlappingSymbolAndCodeCountedOnce() {
        // "$45 USD" must not yield both a $-match and a USD-match.
        let amounts = MoneyExtractor.extract("Paid $45 USD today")
        XCTAssertEqual(amounts.count, 1)
        XCTAssertEqual(amounts.first, .init(currency: "USD", value: 45))
    }

    func testSummaryTotalsPerCurrencyAndEmptyIsNil() {
        let s = MoneyExtractor.summary("Coffee $3, bagel $4.50, and €10 gift.")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("USD 7.50 (×2)"), s ?? "")   // 3 + 4.50
        XCTAssertTrue(s!.contains("EUR 10 (×1)"), s ?? "")
        XCTAssertNil(MoneyExtractor.summary("no prices in this note"))
    }
}
