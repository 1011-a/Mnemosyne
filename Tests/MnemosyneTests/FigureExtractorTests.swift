import XCTest
@testable import Mnemosyne

final class FigureExtractorTests: XCTestCase {

    func testCurrencyFormsSymbolAndWord() {
        let text = "Invoice total $1,234.56, deposit €50, balance 300 USD, fee 75 dollars."
        let values = FigureExtractor.extract(text).map(\.value)
        XCTAssertTrue(values.contains("$1,234.56"))
        XCTAssertTrue(values.contains("€50"))
        XCTAssertTrue(values.contains("300 USD"))
        XCTAssertTrue(values.contains("75 dollars"))
        XCTAssertTrue(FigureExtractor.extract(text).allSatisfy { $0.kind == .currency })
    }

    func testPercentages() {
        let figs = FigureExtractor.extract("Growth was 15% this quarter, churn 3.5 %.")
        XCTAssertEqual(figs.map(\.kind), [.percent, .percent])
        XCTAssertTrue(figs.map(\.value).contains("15%"))
    }

    func testDocumentOrderAndDedupe() {
        let text = "Pay $100 now, then $100 again, plus 10%."
        let figs = FigureExtractor.extract(text)
        XCTAssertEqual(figs.filter { $0.value == "$100" }.count, 1, "duplicate amount collapsed")
        XCTAssertEqual(figs.last?.value, "10%", "later position trails")
    }

    func testSummaryGroupsByKindAndEmpty() {
        let summary = FigureExtractor.summary("Budget $5,000 with a 20% buffer.")
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("Amounts:"))
        XCTAssertTrue(summary!.contains("Percentages:"))
        XCTAssertNil(FigureExtractor.summary("No numbers worth noting here."))
        XCTAssertNil(FigureExtractor.summary(""))
    }
}
