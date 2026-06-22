import XCTest
@testable import Mnemosyne

final class TableOfContentsTests: XCTestCase {

    func testBuildsIndentedLinkedTOC() {
        let md = "# Title\n## Section A\n### Sub Point\n## Section B"
        let toc = TableOfContents.generate(md)
        XCTAssertEqual(toc, """
        - [Title](#title)
          - [Section A](#section-a)
            - [Sub Point](#sub-point)
          - [Section B](#section-b)
        """)
    }

    func testIndentRelativeToShallowestHeading() {
        // Shallowest is ##, so it sits at the left margin.
        let toc = TableOfContents.generate("## Top\n### Child")
        XCTAssertEqual(toc, "- [Top](#top)\n  - [Child](#child)")
    }

    func testNoHeadingsIsNil() {
        XCTAssertNil(TableOfContents.generate("just prose, no headings"))
        XCTAssertNil(TableOfContents.generate(""))
    }
}
