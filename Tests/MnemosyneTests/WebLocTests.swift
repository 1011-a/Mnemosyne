import XCTest
@testable import Mnemosyne

final class WebLocTests: XCTestCase {

    private func plist(_ dict: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    func testExtractsURLAndSlugWords() {
        let data = plist(["URL": "https://example.com/how-to-bake-bread"])
        let text = WebLocExtractor.parse(data)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("https://example.com/how-to-bake-bread"))
        XCTAssertTrue(text!.contains("example.com how to bake bread"), "got: \(text!)")
    }

    func testBinaryPlistAlsoWorks() {
        let data = try! PropertyListSerialization.data(
            fromPropertyList: ["URL": "https://news.site/world/story_42"], format: .binary, options: 0)
        let text = WebLocExtractor.parse(data)
        XCTAssertTrue(text?.contains("news.site world story 42") == true, "got: \(text ?? "nil")")
    }

    func testRootDomainOnly() {
        let text = WebLocExtractor.readable("https://apple.com")
        XCTAssertEqual(text, "https://apple.com\napple.com")
    }

    func testNonPlistDataIsNil() {
        XCTAssertNil(WebLocExtractor.parse(Data("not a plist".utf8)))
    }

    func testPlistWithoutURLKeyIsNil() {
        XCTAssertNil(WebLocExtractor.parse(plist(["Title": "no url here"])))
    }

    func testTypeDetectorMapsWebLocToWebpage() {
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/link.webloc")), .webpage)
    }
}
