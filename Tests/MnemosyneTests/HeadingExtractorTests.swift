import XCTest
@testable import Mnemosyne

final class HeadingExtractorTests: XCTestCase {

    func testExtractsAtxHeadingsWithLevels() {
        let text = """
        # Title
        Some intro prose.
        ## Section A
        content here
        ### Sub A.1
        ## Section B
        """
        let heads = HeadingExtractor.extract(text)
        XCTAssertEqual(heads.count, 4)
        XCTAssertEqual(heads[0].level, 1)
        XCTAssertEqual(heads[0].title, "Title")
        XCTAssertEqual(heads[2].level, 3)
        XCTAssertEqual(heads[2].title, "Sub A.1")
        XCTAssertEqual(heads[3].title, "Section B")
    }

    func testIgnoresNonHeadingsAndEmpty() {
        // "#tag" has no space → not a heading; bare "###" has no title; 7 hashes → too deep.
        XCTAssertTrue(HeadingExtractor.extract("#tag is not a heading\nplain line\n###").isEmpty)
        XCTAssertTrue(HeadingExtractor.extract("####### too deep").isEmpty)
        XCTAssertTrue(HeadingExtractor.extract("").isEmpty)
        XCTAssertNil(HeadingExtractor.outline("no headings at all"))
    }

    func testOutlineIndentsRelativeToShallowest() {
        // Shallowest heading is ##, so it should sit at the left margin.
        let text = """
        ## Top
        #### Deep
        ### Mid
        """
        let outline = HeadingExtractor.outline(text)
        XCTAssertNotNil(outline)
        let lines = outline!.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "• Top")
        XCTAssertEqual(lines[1], "    • Deep")   // level 4 - base 2 = 2 → 4 spaces
        XCTAssertEqual(lines[2], "  • Mid")      // level 3 - base 2 = 1 → 2 spaces
    }

    func testStripsTrailingHashesAndWhitespace() {
        let heads = HeadingExtractor.extract("##   Spaced Heading   ##")
        XCTAssertEqual(heads.count, 1)
        XCTAssertEqual(heads[0].title, "Spaced Heading")
    }
}
