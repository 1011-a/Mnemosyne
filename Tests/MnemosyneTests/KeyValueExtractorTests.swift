import XCTest
@testable import Mnemosyne

final class KeyValueExtractorTests: XCTestCase {

    func testExtractsLabelledFieldsIncludingBulletsAndMultiWordKeys() {
        let text = """
        Status: Done
        Due date: Friday
        - Owner: Sam
        """
        let pairs = KeyValueExtractor.extract(text)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[0].key, "Status")
        XCTAssertEqual(pairs[0].value, "Done")
        XCTAssertEqual(pairs[1].key, "Due date")
        XCTAssertEqual(pairs[2].key, "Owner")       // leading bullet stripped
        XCTAssertEqual(pairs[2].value, "Sam")
    }

    func testExcludesTimesUrlsAndHeadings() {
        // Colon-without-space cases must NOT be treated as fields.
        XCTAssertTrue(KeyValueExtractor.extract("Meeting at 12:30 today").isEmpty)
        XCTAssertTrue(KeyValueExtractor.extract("Link: see http://example.com").first?.value == "see http://example.com",
                      "the field 'Link: …' is valid; the URL inside the value is fine")
        XCTAssertTrue(KeyValueExtractor.extract("# Heading: not a field").isEmpty)
        XCTAssertTrue(KeyValueExtractor.extract("ratio is 3:4 overall").isEmpty)
    }

    func testDedupesKeysKeepingFirst() {
        let pairs = KeyValueExtractor.extract("Status: Open\nStatus: Closed")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].value, "Open")
    }

    func testSummaryAndEmpty() {
        let s = KeyValueExtractor.summary("Priority: High\nStage: Review")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("2 field(s)"), s ?? "")
        XCTAssertTrue(s!.contains("Priority: High"), s ?? "")
        XCTAssertNil(KeyValueExtractor.summary("just a prose line with no fields"))
        XCTAssertNil(KeyValueExtractor.summary(""))
    }
}
