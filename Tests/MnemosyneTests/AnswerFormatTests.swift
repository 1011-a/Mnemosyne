import XCTest
@testable import Mnemosyne

final class AnswerFormatTests: XCTestCase {

    func testLeadThenBullets() {
        let blocks = AnswerFormat.parse("""
        You compared FAISS and SQLite-vss.

        - FAISS is fastest but memory-hungry [1].
        - SQLite-vss ships as one file [2].
        """)
        XCTAssertEqual(blocks.first, .lead("You compared FAISS and SQLite-vss."))
        XCTAssertEqual(blocks.filter { if case .bullet = $0 { return true } else { return false } }.count, 2)
        XCTAssertEqual(blocks[1], .bullet("FAISS is fastest but memory-hungry [1]."))
    }

    func testNumberedBulletsAndDifferentMarkers() {
        let blocks = AnswerFormat.parse("Summary line.\n1. first\n2) second\n* third\n• fourth")
        let bullets = blocks.compactMap { if case .bullet(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(bullets, ["first", "second", "third", "fourth"])
    }

    func testHeadingDetection() {
        let blocks = AnswerFormat.parse("Lead.\n## Details\nsome text\n**Bold heading**")
        XCTAssertTrue(blocks.contains(.heading("Details")))
        XCTAssertTrue(blocks.contains(.heading("Bold heading")))
    }

    func testFirstParagraphIsLeadNotParagraph() {
        let blocks = AnswerFormat.parse("One.\n\nTwo.\n\nThree.")
        XCTAssertEqual(blocks[0], .lead("One."))
        XCTAssertEqual(blocks[1], .paragraph("Two."))
        XCTAssertEqual(blocks[2], .paragraph("Three."))
    }

    func testEmptyInput() {
        XCTAssertTrue(AnswerFormat.parse("   \n\n  ").isEmpty)
    }

    func testMarkdownTableParsed() {
        let blocks = AnswerFormat.parse("""
        Here is the comparison.

        | Feature | FAISS | SQLite-vss |
        | --- | --- | --- |
        | Speed | Fast | Medium |
        | Memory | High | Low |
        """)
        XCTAssertEqual(blocks[0], .lead("Here is the comparison."))
        guard case .table(let headers, let rows) = blocks[1] else {
            return XCTFail("expected a table block, got \(blocks)")
        }
        XCTAssertEqual(headers, ["Feature", "FAISS", "SQLite-vss"])
        XCTAssertEqual(rows, [["Speed", "Fast", "Medium"], ["Memory", "High", "Low"]])
    }

    func testTableWithoutOuterPipesAndAlignmentColons() {
        let blocks = AnswerFormat.parse("""
        Metric | Value
        :--- | ---:
        Recall | 0.98
        """)
        guard case .table(let headers, let rows) = blocks.first else {
            return XCTFail("expected a table, got \(blocks)")
        }
        XCTAssertEqual(headers, ["Metric", "Value"])
        XCTAssertEqual(rows, [["Recall", "0.98"]])
    }

    func testRaggedRowsPaddedAndTruncatedToHeaderWidth() {
        let blocks = AnswerFormat.parse("| A | B | C |\n|---|---|---|\n| 1 | 2 |\n| x | y | z | extra |")
        guard case .table(_, let rows) = blocks.first else { return XCTFail("expected table") }
        XCTAssertEqual(rows[0], ["1", "2", ""])        // padded
        XCTAssertEqual(rows[1], ["x", "y", "z"])       // truncated
    }

    func testLonePipeIsNotATable() {
        // A pipe in prose without a separator row must stay prose, not a table.
        let blocks = AnswerFormat.parse("Use cat foo | grep bar to filter.")
        XCTAssertEqual(blocks, [.lead("Use cat foo | grep bar to filter.")])
    }

    func testStatLinesGroupedIntoTiles() {
        let blocks = AnswerFormat.parse("""
        Here is your knowledge base at a glance.

        Items: 88
        Chunks: 823
        Indexed: 36.8 MB
        """)
        XCTAssertEqual(blocks[0], .lead("Here is your knowledge base at a glance."))
        XCTAssertEqual(blocks[1], .stats([
            AnswerStat(label: "Items", value: "88"),
            AnswerStat(label: "Chunks", value: "823"),
            AnswerStat(label: "Indexed", value: "36.8 MB"),
        ]))
    }

    func testBoldAndBulletedStats() {
        let blocks = AnswerFormat.parse("**Total items:** 88\n- Storage: 36.8 MB")
        XCTAssertEqual(blocks, [.stats([
            AnswerStat(label: "Total items", value: "88"),
            AnswerStat(label: "Storage", value: "36.8 MB"),
        ])])
    }

    func testSingleStatLineStaysProse() {
        // Only one "Label: value" line — not enough to form a stat block.
        let blocks = AnswerFormat.parse("Note: 42")
        XCTAssertEqual(blocks, [.lead("Note: 42")])
    }

    func testBlockquoteMergesConsecutiveLines() {
        let blocks = AnswerFormat.parse("""
        As the paper notes:

        > FAISS is fast
        > but memory-hungry [1].

        That matters.
        """)
        XCTAssertEqual(blocks[0], .lead("As the paper notes:"))
        XCTAssertEqual(blocks[1], .quote("FAISS is fast but memory-hungry [1]."))
        XCTAssertEqual(blocks.last, .paragraph("That matters."))
    }

    func testSingleGreaterThanLineIsNotAQuote() {
        // "5 > 3" in prose must not become a quote (needs "> " prefix).
        let blocks = AnswerFormat.parse("Note that 5 > 3 always.")
        XCTAssertEqual(blocks, [.lead("Note that 5 > 3 always.")])
    }

    func testFencedCodeBlockParsedAndIndentationPreserved() {
        let blocks = AnswerFormat.parse("""
        Here is the function:

        ```swift
        func add(_ a: Int, _ b: Int) -> Int {
            return a + b
        }
        ```

        That's it.
        """)
        XCTAssertEqual(blocks[0], .lead("Here is the function:"))
        XCTAssertEqual(blocks[1], .code("func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}"))
        XCTAssertEqual(blocks.last, .paragraph("That's it."))
    }

    func testCodeFenceContentNotMisparsedAsBulletsOrTables() {
        let blocks = AnswerFormat.parse("""
        ```
        - not a bullet
        | not | a table |
        Key: not a stat
        ```
        """)
        guard case .code(let src) = blocks.first else { return XCTFail("expected code, got \(blocks)") }
        XCTAssertTrue(src.contains("- not a bullet"))
        XCTAssertTrue(src.contains("| not | a table |"))
        XCTAssertEqual(blocks.count, 1, "everything inside the fence stays one code block")
    }

    func testTwoColumnNumericTableBecomesStatTiles() {
        let blocks = AnswerFormat.parse("""
        | Metric | Value |
        | --- | --- |
        | Recall | 0.98 |
        | MRR | 1.00 |
        | Items | 88 |
        """)
        guard case .stats(let stats) = blocks.first else {
            return XCTFail("a 2-col numeric table should render as stat tiles, got \(blocks)")
        }
        XCTAssertEqual(stats, [
            AnswerStat(label: "Recall", value: "0.98"),
            AnswerStat(label: "MRR", value: "1.00"),
            AnswerStat(label: "Items", value: "88"),
        ])
    }

    func testTwoColumnTextTableStaysATable() {
        // Long text values (no digits) must remain a table, not tiles.
        let blocks = AnswerFormat.parse("""
        | Name | Email |
        | --- | --- |
        | Jane Smith | jane@acme.example |
        | Bob Jones | bob@acme.example |
        """)
        guard case .table = blocks.first else {
            return XCTFail("a 2-col text table should stay a table, got \(blocks)")
        }
    }

    func testThreeColumnTableStaysATable() {
        let blocks = AnswerFormat.parse("""
        | Dimension | FAISS | SQLite |
        | --- | --- | --- |
        | Speed | 9 | 5 |
        """)
        guard case .table = blocks.first else {
            return XCTFail("a 3-col table must stay a table, got \(blocks)")
        }
    }

    func testProseWithColonsIsNotStats() {
        // Wordy values must never be mistaken for metrics.
        let blocks = AnswerFormat.parse("""
        Summary: the project is finished and shipped.
        Reminder: remember to back up your files tonight.
        """)
        XCTAssertFalse(blocks.contains { if case .stats = $0 { return true } else { return false } })
    }
}
