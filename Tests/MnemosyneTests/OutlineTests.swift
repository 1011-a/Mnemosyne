import XCTest
@testable import Mnemosyne

final class OutlineTests: XCTestCase {

    func testMarkdownHeadingsWithLevels() {
        let md = """
        # Title
        intro prose here
        ## Section One
        more text
        ### Sub A
        #notahashtag still prose
        """
        let h = Outline.extract(md)
        XCTAssertEqual(h, [
            .init(level: 1, title: "Title"),
            .init(level: 2, title: "Section One"),
            .init(level: 3, title: "Sub A")
        ])
    }

    func testAtxRejectsHashtagAndTrimsTrailingHashes() {
        XCTAssertNil(Outline.atxHeading("#hashtag"), "no space after # ⇒ not a heading")
        XCTAssertEqual(Outline.atxHeading("## Heading ##"), .init(level: 2, title: "Heading"))
        XCTAssertNil(Outline.atxHeading("####### too many"), "7 hashes is not a heading")
    }

    func testNumberedSections() {
        XCTAssertEqual(Outline.numberedHeading("1. Introduction"), .init(level: 1, title: "Introduction"))
        XCTAssertEqual(Outline.numberedHeading("2.3 Methods And Materials"), .init(level: 2, title: "Methods And Materials"))
        // Lowercase list item / sentence-like lines are NOT headings.
        XCTAssertNil(Outline.numberedHeading("1. buy milk"))
        XCTAssertNil(Outline.numberedHeading("1. This is actually a full sentence that ends with a period."))
    }

    func testAllCapsHeaders() {
        XCTAssertEqual(Outline.allCapsHeading("INTRODUCTION"), .init(level: 1, title: "INTRODUCTION"))
        XCTAssertEqual(Outline.allCapsHeading("RELATED WORK"), .init(level: 1, title: "RELATED WORK"))
        XCTAssertNil(Outline.allCapsHeading("Mixed Case Line"))
        XCTAssertNil(Outline.allCapsHeading("ENDS WITH PERIOD."))
    }

    func testRenderIndentsByLevel() {
        let r = Outline.render([
            .init(level: 1, title: "Top"),
            .init(level: 2, title: "Child"),
            .init(level: 3, title: "Grandchild")
        ])
        XCTAssertEqual(r, "• Top\n  • Child\n    • Grandchild")
    }

    func testNoHeadingsInPlainProse() {
        XCTAssertTrue(Outline.extract("just a paragraph of normal text.\nAnother sentence here.").isEmpty)
    }
}
