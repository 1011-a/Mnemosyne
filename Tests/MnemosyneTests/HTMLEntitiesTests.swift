import XCTest
@testable import Mnemosyne

final class HTMLEntitiesTests: XCTestCase {

    func testEscapesSpecialChars() {
        XCTAssertEqual(HTMLEntities.escape("<div> & \"q\" 'a'"),
                       "&lt;div&gt; &amp; &quot;q&quot; &#39;a&#39;")
    }

    func testAmpersandEscapedFirst() {
        XCTAssertEqual(HTMLEntities.escape("a < b & c"), "a &lt; b &amp; c")
    }

    func testUnescapeDecodes() {
        XCTAssertEqual(HTMLEntities.unescape("&lt;b&gt;tag&lt;/b&gt;"), "<b>tag</b>")
        XCTAssertEqual(HTMLEntities.unescape("&amp;lt;"), "&lt;")   // escaped ampersand decoded last
    }

    func testRoundTrip() {
        let original = "if (a < b && c > d) return \"x\";"
        XCTAssertEqual(HTMLEntities.unescape(HTMLEntities.escape(original)), original)
    }
}
