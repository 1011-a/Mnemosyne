import XCTest
@testable import Mnemosyne

final class SubtitleTests: XCTestCase {

    func testParsesSRTToCleanDialogue() {
        let text = SubtitleExtractor.parse("""
        1
        00:00:01,000 --> 00:00:04,000
        Welcome to the course.

        2
        00:00:04,500 --> 00:00:07,000
        Today we cover vector search.
        """)
        XCTAssertEqual(text, "Welcome to the course. Today we cover vector search.")
    }

    func testParsesVTTAndStripsHeader() {
        let text = SubtitleExtractor.parse("""
        WEBVTT

        NOTE this is a comment

        00:00:00.000 --> 00:00:02.000
        Hello world.
        """)
        XCTAssertEqual(text, "Hello world.")
    }

    func testStripsInlineMarkup() {
        let text = SubtitleExtractor.parse("""
        1
        00:00:01,000 --> 00:00:02,000
        <i>Italic</i> and {\\an8}positioned text
        """)
        XCTAssertEqual(text, "Italic and positioned text")
    }

    func testDropsConsecutiveDuplicates() {
        let text = SubtitleExtractor.parse("""
        1
        00:00:01,000 --> 00:00:02,000
        Same line

        2
        00:00:02,000 --> 00:00:03,000
        Same line
        """)
        XCTAssertEqual(text, "Same line")
    }

    func testNonSubtitleTextYieldsItself() {
        XCTAssertEqual(SubtitleExtractor.parse("just a sentence"), "just a sentence")
    }

    func testTypeDetectorMapsSubtitlesToText() {
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/movie.srt")), .text)
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/lecture.vtt")), .text)
        XCTAssertTrue(SubtitleExtractor.isSubtitle(URL(fileURLWithPath: "/tmp/x.sbv")))
    }
}
