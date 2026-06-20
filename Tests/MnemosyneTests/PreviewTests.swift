import XCTest
import AppKit
@testable import Mnemosyne

final class PreviewTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Prev-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testImagePreviewProducesPNG() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pic.png")
        // Write a real 200x200 PNG.
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 200, height: 200).fill(); img.unlockFocus()
        let tiff = img.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: url)

        let data = PreviewLoader.previewPNG(for: url, kind: .image)
        XCTAssertNotNil(data)
        XCTAssertNotNil(NSImage(data: data!), "preview bytes decode to an image")
    }

    func testPDFPreviewProducesPNG() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.setFillColor(NSColor.white.cgColor); ctx.fill(box); ctx.endPDFPage(); ctx.closePDF()
        try data.write(to: url)

        XCTAssertNotNil(PreviewLoader.previewPNG(for: url, kind: .pdf), "PDF first page renders")
    }

    func testNonVisualKindReturnsNil() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(PreviewLoader.previewPNG(for: url, kind: .text))
        XCTAssertNil(PreviewLoader.previewPNG(for: url, kind: .markdown))
    }

    func testMissingFileReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID()).png")
        XCTAssertNil(PreviewLoader.previewPNG(for: url, kind: .image))
    }
}
