import XCTest
@testable import Mnemosyne

final class SlugifierTests: XCTestCase {

    func testBasicTitleBecomesHyphenatedLowercase() {
        XCTAssertEqual(Slugifier.slugify("My Great Note!"), "my-great-note")
    }

    func testFoldsAccentsToAscii() {
        XCTAssertEqual(Slugifier.slugify("Café résumé"), "cafe-resume")
    }

    func testCollapsesPunctuationAndTrimsEdges() {
        XCTAssertEqual(Slugifier.slugify("  multiple   spaces--and__symbols!! "), "multiple-spaces-and-symbols")
    }

    func testClampsLengthWithoutTrailingHyphenAndEmptyForNonAscii() {
        XCTAssertEqual(Slugifier.slugify("hello world foo", maxLength: 11), "hello-world")  // cut at a boundary, no trailing -
        XCTAssertEqual(Slugifier.slugify("！？。"), "")   // no slug-able characters
        XCTAssertEqual(Slugifier.slugify(""), "")
    }
}
