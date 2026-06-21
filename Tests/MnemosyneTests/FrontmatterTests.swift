import XCTest
@testable import Mnemosyne

final class FrontmatterTests: XCTestCase {

    private let note = """
    ---
    title: My Note
    tags: work, ideas
    date: 2026-06-15
    pinned: "true"
    ---
    # Body starts here
    Some content.
    """

    func testParsesLeadingBlock() {
        let pairs = Frontmatter.parse(note)
        XCTAssertNotNil(pairs)
        let dict = Dictionary(pairs!.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["title"], "My Note")
        XCTAssertEqual(dict["tags"], "work, ideas")
        XCTAssertEqual(dict["date"], "2026-06-15")
        XCTAssertEqual(dict["pinned"], "true")          // surrounding quotes stripped
    }

    func testStopsAtClosingFenceIgnoringBody() {
        let pairs = Frontmatter.parse(note)
        XCTAssertEqual(pairs?.count, 4)                  // body "# Body…" not included
    }

    func testNoFrontmatterReturnsNil() {
        XCTAssertNil(Frontmatter.parse("# Just a heading\nno frontmatter here"))
        XCTAssertNil(Frontmatter.parse("---\ntitle: x\nno closing fence"))   // unterminated
        XCTAssertNil(Frontmatter.summary("plain text"))
    }

    func testValueWithColonKeepsRemainder() {
        let pairs = Frontmatter.parse("---\ntime: 12:30 PM\n---")
        XCTAssertEqual(pairs?.first?.key, "time")
        XCTAssertEqual(pairs?.first?.value, "12:30 PM")
    }
}
