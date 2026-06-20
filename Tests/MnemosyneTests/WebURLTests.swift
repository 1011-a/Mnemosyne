import XCTest
@testable import Mnemosyne

final class WebURLTests: XCTestCase {

    private func item(kind: ItemKind, path: String) -> KnowledgeItem {
        KnowledgeItem(id: "i", path: path, title: "t", kind: kind,
                      contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date())
    }

    func testWebpageWithHTTPPathHasWebURL() {
        let it = item(kind: .webpage, path: "https://example.com/page")
        XCTAssertEqual(it.webURL, URL(string: "https://example.com/page"))
    }

    func testFileItemHasNoWebURL() {
        XCTAssertNil(item(kind: .pdf, path: "/Users/me/doc.pdf").webURL)
        XCTAssertNil(item(kind: .markdown, path: "/tmp/notes.md").webURL)
    }

    func testWebpageKindButFilePathHasNoWebURL() {
        // A .webpage item whose path is a local file (e.g. a .webloc on disk) is
        // not a live link to open in a browser.
        XCTAssertNil(item(kind: .webpage, path: "/Users/me/link.webloc").webURL)
    }
}
