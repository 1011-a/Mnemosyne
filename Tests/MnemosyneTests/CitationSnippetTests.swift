import XCTest
@testable import Mnemosyne

final class CitationSnippetTests: XCTestCase {

    private func cite(_ snippet: String) -> Citation {
        Citation(index: 1, title: "doc.md", path: "/tmp/doc.md", snippet: snippet)
    }

    func testCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(cite("FAISS  provides\n efficient\tsearch.").snippetPreview,
                       "FAISS provides efficient search.")
    }

    func testTrimsLeadingTrailing() {
        XCTAssertEqual(cite("   hello world  \n").snippetPreview, "hello world")
    }

    func testEmptySnippetIsEmptyPreview() {
        XCTAssertTrue(cite("").snippetPreview.isEmpty)
        XCTAssertTrue(cite("   \n\t ").snippetPreview.isEmpty)
    }
}
