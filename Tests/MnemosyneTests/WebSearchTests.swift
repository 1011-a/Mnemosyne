import XCTest
@testable import Mnemosyne

final class WebSearchTests: XCTestCase {

    func testDecodesDuckDuckGoRedirect() {
        let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage%3Fa%3D1&rut=x"
        XCTAssertEqual(WebSearchClient.decodeDDGRedirect(href), "https://example.com/page?a=1")
        // A plain protocol-relative link gets https.
        XCTAssertEqual(WebSearchClient.decodeDDGRedirect("//foo.com/x"), "https://foo.com/x")
    }

    func testParsesDuckDuckGoHTML() {
        let html = """
        <div class="result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org">The Swift Programming Language</a>
          <a class="result__snippet" href="x">Swift is a <b>general-purpose</b> language.</a>
        </div>
        <div class="result">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fdocs">Example Docs</a>
          <a class="result__snippet" href="y">Reference material &amp; guides.</a>
        </div>
        """
        let r = WebSearchClient.parseDuckDuckGo(html, limit: 5)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].title, "The Swift Programming Language")
        XCTAssertEqual(r[0].url, "https://swift.org")
        XCTAssertEqual(r[0].snippet, "Swift is a general-purpose language.")
        XCTAssertEqual(r[1].url, "https://example.org/docs")
        XCTAssertEqual(r[1].snippet, "Reference material & guides.")
    }

    func testHtmlToTextStripsTagsScriptsAndEntities() {
        let html = """
        <html><head><style>.x{color:red}</style><script>alert('hi')</script></head>
        <body><h1>Title</h1><p>Hello&nbsp;&amp; welcome to <b>Swift</b> &lt;tags&gt;.</p>
        <!-- a comment --></body></html>
        """
        let text = WebSearchClient.htmlToText(html)
        XCTAssertFalse(text.contains("alert"), "scripts removed")
        XCTAssertFalse(text.contains("color:red"), "styles removed")
        XCTAssertFalse(text.contains("<h1>"), "real tags removed")
        XCTAssertFalse(text.contains("<b>"), "real tags removed")
        XCTAssertTrue(text.contains("Title"))
        // entity decoding is intentional — &lt;tags&gt; becomes literal <tags>.
        XCTAssertTrue(text.contains("Hello & welcome to Swift <tags>."))
    }

    func testEmptyQueryReturnsNothing() async {
        let client = WebSearchClient(serpApiKey: "")
        let r = await client.search("   ")
        XCTAssertTrue(r.isEmpty)
    }

    /// LIVE: keyless DuckDuckGo fallback actually returns results (gated — network).
    /// Run: MNEMO_LIVE_WEB=1 swift test --filter WebSearchTests
    func testLiveKeylessWebSearch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_WEB"] == "1", "set MNEMO_LIVE_WEB=1")
        let r = await WebSearchClient(serpApiKey: "").search("swift programming language", limit: 4)
        print("WEB_RESULTS>>> \(r.count): \(r.prefix(2).map { $0.url })")
        XCTAssertFalse(r.isEmpty, "keyless web search should return results")
    }
}
