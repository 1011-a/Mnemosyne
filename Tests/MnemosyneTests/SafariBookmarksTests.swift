import XCTest
@testable import Mnemosyne

final class SafariBookmarksTests: XCTestCase {

    private func plist(_ obj: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
    }

    /// A Safari-shaped tree: root list → a folder → two leaves.
    private func sampleTree() -> [String: Any] {
        func leaf(_ title: String, _ url: String) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url,
             "URIDictionary": ["title": title]]
        }
        return [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Tech",
                 "Children": [leaf("Swift.org", "https://swift.org"),
                              leaf("Apple Developer", "https://developer.apple.com")]],
            ],
        ]
    }

    func testFlattensNestedBookmarks() {
        let marks = SafariBookmarksParser.parse(plist(sampleTree()))
        XCTAssertEqual(marks, [
            Bookmark(title: "Swift.org", url: "https://swift.org"),
            Bookmark(title: "Apple Developer", url: "https://developer.apple.com"),
        ])
    }

    func testFallsBackToURLWhenNoTitle() {
        let tree: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://x.com"]],
        ]
        XCTAssertEqual(SafariBookmarksParser.parse(plist(tree)), [Bookmark(title: "https://x.com", url: "https://x.com")])
    }

    func testDeduplicatesByURL() {
        func leaf(_ u: String) -> [String: Any] { ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": u] }
        let tree: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList",
                                   "Children": [leaf("https://dup.com"), leaf("https://dup.com")]]
        XCTAssertEqual(SafariBookmarksParser.parse(plist(tree)).count, 1)
    }

    func testSkipsReadingList() {
        func leaf(_ u: String) -> [String: Any] { ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": u] }
        let tree: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList",
                 "Children": [leaf("https://later.com")]],
                leaf("https://keep.com"),
            ],
        ]
        XCTAssertEqual(SafariBookmarksParser.parse(plist(tree)), [Bookmark(title: "https://keep.com", url: "https://keep.com")])
    }

    func testNonPlistOrEmptyIsEmpty() {
        XCTAssertTrue(SafariBookmarksParser.parse(Data("nope".utf8)).isEmpty)
        XCTAssertTrue(SafariBookmarksParser.parse(Data()).isEmpty)
    }

    @MainActor
    func testIngestBookmarksCreatesSearchableWebpageItems() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BM-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let ingestor = Ingestor(store: store, embedder: Embedder(),
                                ollama: OllamaClient(config: .load()), settings: TestSupport.settings())
        await ingestor.ingestBookmarks([
            Bookmark(title: "Swift 6 release notes", url: "https://swift.org/blog/swift-6-released"),
            Bookmark(title: "Apple", url: "https://apple.com"),
        ], progress: IngestProgress())

        let count = try await store.itemCount()
        XCTAssertEqual(count, 2, "each bookmark becomes one item")
        // The slug words are searchable, so a bookmark is findable by its title path.
        let hits = try await store.itemIDsMatchingContent("swift 6 released")
        XCTAssertEqual(hits.count, 1)
    }
}
