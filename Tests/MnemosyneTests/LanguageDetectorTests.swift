import XCTest
@testable import Mnemosyne

/// NLLanguageRecognizer is model-driven; these use unambiguous text and assert the
/// language family (robust: Chinese may resolve to zh-Hans/zh-Hant) plus the empty/short
/// guard and the code→name mapping.
final class LanguageDetectorTests: XCTestCase {

    func testDetectsCommonLanguages() {
        XCTAssertEqual(LanguageDetector.detect("The quick brown fox jumps over the lazy dog.")?.dominant, "en")
        XCTAssertEqual(LanguageDetector.detect("Bonjour, comment ça va aujourd'hui mon cher ami ?")?.dominant, "fr")
        let zh = LanguageDetector.detect("你好，今天天气非常好，我们一起去公园散步吧。")?.dominant
        XCTAssertTrue(zh?.hasPrefix("zh") ?? false, "Chinese should resolve to a zh-* code (got \(zh ?? "nil"))")
    }

    func testNameMapping() {
        XCTAssertEqual(LanguageDetector.name(for: "en"), "English")
        XCTAssertEqual(LanguageDetector.name(for: "de"), "German")
    }

    func testSummaryFormat() {
        let summary = LanguageDetector.summary("This is clearly an English sentence with enough signal.")
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("English"), "summary: \(summary ?? "")")
        XCTAssertTrue(summary!.contains("(en"), "summary should include the code: \(summary ?? "")")
    }

    func testTooShortOrEmpty() {
        XCTAssertNil(LanguageDetector.detect(""))
        XCTAssertNil(LanguageDetector.detect("a"))
        XCTAssertNil(LanguageDetector.summary("  "))
    }
}
