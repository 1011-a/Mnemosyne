import XCTest
@testable import Mnemosyne

final class FileTypeTests: XCTestCase {

    private func kind(_ name: String) -> ItemKind? {
        TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testAudioExtensionsDetected() {
        XCTAssertEqual(kind("lecture.m4a"), .audioTranscript)
        XCTAssertEqual(kind("podcast.mp3"), .audioTranscript)
        XCTAssertEqual(kind("memo.wav"), .audioTranscript)
        XCTAssertEqual(kind("song.flac"), .audioTranscript)
    }

    func testWordDocsDetected() {
        XCTAssertEqual(kind("report.docx"), .wordDoc)
        XCTAssertEqual(kind("legacy.doc"), .wordDoc)
    }

    func testExistingTypesStillCorrect() {
        XCTAssertEqual(kind("notes.md"), .markdown)
        XCTAssertEqual(kind("main.swift"), .code)
        XCTAssertEqual(kind("paper.pdf"), .pdf)
        XCTAssertEqual(kind("photo.jpg"), .image)
        XCTAssertEqual(kind("data.csv"), .data)
        XCTAssertEqual(kind("page.html"), .html)
    }

    func testVideoAndArchivesSkipped() {
        XCTAssertNil(kind("movie.mp4"))
        XCTAssertNil(kind("clip.mov"))
        XCTAssertNil(kind("archive.zip"))
    }
}
