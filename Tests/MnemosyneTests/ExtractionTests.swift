import XCTest
import PDFKit
import AppKit
@testable import Mnemosyne

final class ExtractionTests: XCTestCase {

    private func kind(_ name: String) -> ItemKind? {
        TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    /// Build a PNG at an EXACT pixel size (no screen-scale backing, unlike NSImage).
    private func pngData(pixelsWide w: Int, pixelsHigh h: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A large image is downscaled (long edge ≤ 1024) before going to the vision
    /// model — this is the ~2× ingest speedup for big retina screenshots/photos.
    func testLargeImageIsDownscaledForVision() throws {
        let png = try pngData(pixelsWide: 3000, pixelsHigh: 2000)
        let out = ContentExtractor.downscaledForVision(png, maxEdge: 1024)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: out))
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), 1024,
                                 "long edge must be capped to maxEdge")
        XCTAssertEqual(rep.pixelsWide, 1024, "long edge scaled to exactly maxEdge")
    }

    /// A small image is left alone (never upscaled — that would only waste pixels).
    func testSmallImageNotUpscaled() throws {
        let png = try pngData(pixelsWide: 400, pixelsHigh: 300)
        let out = ContentExtractor.downscaledForVision(png, maxEdge: 1024)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: out))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 400, "small image must keep its size")
    }

    func testIWorkAndEmailDetected() {
        XCTAssertEqual(kind("report.pages"), .iwork)
        XCTAssertEqual(kind("deck.key"), .iwork)
        XCTAssertEqual(kind("budget.numbers"), .iwork)
        XCTAssertEqual(kind("message.eml"), .email)
        XCTAssertEqual(kind("saved.emlx"), .email)
    }

    func testEmailParsingExtractsHeadersAndBody() {
        let eml = """
        From: alice@example.com
        To: bob@example.com
        Subject: Quarterly numbers
        Date: Mon, 1 Jun 2026 10:00:00 +0000
        Content-Type: text/plain

        Revenue grew 12 percent this quarter. See attached.
        """
        let out = EmailExtractor.parse(eml)
        XCTAssertTrue(out.contains("Subject: Quarterly numbers"))
        XCTAssertTrue(out.contains("From: alice@example.com"))
        XCTAssertTrue(out.contains("Revenue grew 12 percent"))
    }

    func testEmailHTMLBodyStripped() {
        let eml = """
        Subject: Hello
        Content-Type: text/html

        <html><body><h1>Hi there</h1><p>Welcome &amp; enjoy</p></body></html>
        """
        let out = EmailExtractor.parse(eml)
        XCTAssertTrue(out.contains("Hi there"))
        XCTAssertTrue(out.contains("Welcome & enjoy"))
        XCTAssertFalse(out.contains("<h1>"))
    }

    func testEmlxByteCountPrefixStripped() {
        let emlx = """
        1234
        Subject: Receipt
        Content-Type: text/plain

        Your order shipped.
        """
        let out = EmailExtractor.parse(emlx)
        XCTAssertTrue(out.contains("Subject: Receipt"))
        XCTAssertFalse(out.contains("1234"))
    }

    func testIWorkExtractionReadsEmbeddedPreviewPDF() async throws {
        let fm = FileManager.default
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Doc-\(UUID().uuidString).pages", isDirectory: true)
        let ql = bundle.appendingPathComponent("QuickLook")
        try fm.createDirectory(at: ql, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle) }

        // Build a real one-page PDF with *extractable* text (drawn into a PDF context).
        try writeTextPDF("Mnemosyne iWork preview extraction works",
                         to: ql.appendingPathComponent("Preview.pdf"))

        let extractor = ContentExtractor(ollama: OllamaClient(config: .load()), multimodal: false)
        let text = try await extractor.extract(url: bundle, kind: .iwork)
        XCTAssertTrue(text.contains("iWork preview extraction"), "got: \(text.prefix(120))")
    }

    private func writeTextPDF(_ string: String, to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        (string as NSString).draw(at: NSPoint(x: 72, y: 700),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
        try data.write(to: url)
    }
}
