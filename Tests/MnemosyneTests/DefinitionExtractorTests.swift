import XCTest
@testable import Mnemosyne

final class DefinitionExtractorTests: XCTestCase {

    func testExtractsVariousDefinitionForms() {
        let text = """
        HTTP stands for Hypertext Transfer Protocol.
        A vector is an ordered list of numbers.
        Photosynthesis is the process by which plants make food.
        Latency means the delay before a transfer begins.
        """
        let defs = DefinitionExtractor.extract(text)
        let dict = Dictionary(defs.map { ($0.term, $0.definition) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["HTTP"], "stands for Hypertext Transfer Protocol")
        XCTAssertEqual(dict["Latency"], "means the delay before a transfer begins")
        XCTAssertEqual(dict["Photosynthesis"], "is the process by which plants make food")
        XCTAssertNotNil(dict["A vector"])
    }

    func testExcludesPronounAssertions() {
        // "She is the boss" / "It is a problem" are assertions, not definitions.
        XCTAssertTrue(DefinitionExtractor.extract("She is the boss. It is a problem.").isEmpty)
    }

    func testDedupesTermsAndEmptyIsNil() {
        let defs = DefinitionExtractor.extract("API means one thing. API means another thing.")
        XCTAssertEqual(defs.count, 1, "first definition of a term wins")
        XCTAssertNil(DefinitionExtractor.summary("just an ordinary sentence with no definitions"))
        XCTAssertNil(DefinitionExtractor.summary(""))
    }

    func testSummaryFormat() {
        let s = DefinitionExtractor.summary("REST means Representational State Transfer.")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("1 definition(s)"), s ?? "")
        XCTAssertTrue(s!.contains("REST — means Representational State Transfer"), s ?? "")
    }
}
