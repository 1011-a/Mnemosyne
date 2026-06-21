import XCTest
@testable import Mnemosyne

final class AcronymExtractorTests: XCTestCase {

    func testExtractsDistinctAcronymsInOrder() {
        let text = "The API uses HTTP and JSON over TCP/IP. The API is documented."
        XCTAssertEqual(AcronymExtractor.extract(text), ["API", "HTTP", "JSON", "TCP", "IP"],
                       "distinct, document order; API not repeated")
    }

    func testAllowsTrailingDigits() {
        XCTAssertEqual(AcronymExtractor.extract("Store it in S3 over HTTP2."), ["S3", "HTTP2"])
    }

    func testIgnoresSingleLettersAndLongWords() {
        let acr = AcronymExtractor.extract("I read the INTRODUCTION section. See FAQ.")
        XCTAssertFalse(acr.contains("I"), "single letters are not acronyms")
        XCTAssertFalse(acr.contains("INTRODUCTION"), "a long ALL-CAPS word (>6) is not an acronym")
        XCTAssertTrue(acr.contains("FAQ"))
    }

    func testSummaryAndEmpty() {
        XCTAssertEqual(AcronymExtractor.summary("Uses API and JSON."), "API, JSON")
        XCTAssertNil(AcronymExtractor.summary("no acronyms here at all"))
        XCTAssertNil(AcronymExtractor.summary(""))
    }
}
