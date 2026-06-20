import XCTest
@testable import Mnemosyne

final class OpmlTests: XCTestCase {

    func testParsesSubscriptionList() {
        let text = OpmlExtractor.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>My Feeds</title></head>
          <body>
            <outline text="Tech">
              <outline text="Swift Blog" type="rss" xmlUrl="https://swift.org/atom.xml"/>
              <outline text="Hacker News" type="rss" xmlUrl="https://news.ycombinator.com/rss"/>
            </outline>
          </body>
        </opml>
        """.utf8))
        XCTAssertTrue(text.hasPrefix("My Feeds"), "document title leads: \(text)")
        XCTAssertTrue(text.contains("Tech"))
        XCTAssertTrue(text.contains("Swift Blog — https://swift.org/atom.xml"))
        XCTAssertTrue(text.contains("Hacker News — https://news.ycombinator.com/rss"))
    }

    func testDecodesXMLEntities() {
        let text = OpmlExtractor.parse(Data("""
        <opml><body><outline text="Tom &amp; Jerry"/></body></opml>
        """.utf8))
        XCTAssertEqual(text, "Tom & Jerry")
    }

    func testUsesTitleAttributeWhenNoText() {
        let text = OpmlExtractor.parse(Data("""
        <opml><body><outline title="A Podcast" xmlUrl="https://x.com/feed"/></body></opml>
        """.utf8))
        XCTAssertEqual(text, "A Podcast — https://x.com/feed")
    }

    func testEmptyOrNonOpmlIsEmpty() {
        XCTAssertTrue(OpmlExtractor.parse(Data("not xml".utf8)).isEmpty)
        XCTAssertTrue(OpmlExtractor.parse(Data()).isEmpty)
    }

    func testTypeDetectorRoutesOpml() {
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/feeds.opml")), .text)
        XCTAssertTrue(OpmlExtractor.isOpml(URL(fileURLWithPath: "/tmp/feeds.opml")))
    }
}
