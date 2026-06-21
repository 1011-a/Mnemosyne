import XCTest
@testable import Mnemosyne

final class CodeBlockExtractorTests: XCTestCase {

    func testExtractsBlocksWithLanguage() {
        let text = """
        Intro paragraph.
        ```swift
        let x = 1
        print(x)
        ```
        Some prose.
        ```
        plain code, no language
        ```
        End.
        """
        let blocks = CodeBlockExtractor.extract(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].language, "swift")
        XCTAssertEqual(blocks[0].code, "let x = 1\nprint(x)")
        XCTAssertEqual(blocks[1].language, "")
        XCTAssertEqual(blocks[1].code, "plain code, no language")
    }

    func testSkipsEmptyBlocksAndHandlesNoFences() {
        XCTAssertTrue(CodeBlockExtractor.extract("```\n\n```\njust prose").isEmpty, "empty block + prose → nothing")
        XCTAssertTrue(CodeBlockExtractor.extract("no code here at all").isEmpty)
        XCTAssertTrue(CodeBlockExtractor.extract("").isEmpty)
    }

    func testSummaryListsLanguagesLineCountsAndPreview() {
        let text = "```python\na = 1\nb = 2\nc = 3\n```"
        let s = CodeBlockExtractor.summary(text)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("1 code block"))
        XCTAssertTrue(s!.contains("python (3 lines)"), s ?? "")
        XCTAssertNil(CodeBlockExtractor.summary("no fences"))
    }

    func testSummaryClampsLongBlocks() {
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let s = CodeBlockExtractor.summary("```\n\(body)\n```", previewLines: 5)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("+15 more lines"), "long snippet is clamped: \(s ?? "")")
    }
}
