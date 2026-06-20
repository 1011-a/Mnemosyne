import Foundation
import AppKit
@testable import Mnemosyne

enum TestSupport {
    static var liveDeepSeekEnabled: Bool {
        ProcessInfo.processInfo.environment["MNEMO_LIVE_DEEPSEEK"] == "1"
    }

    static func tempDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func samplePNGData(label: String = "Mnemosyne test image") -> Data {
        let width = 640
        let height = 360
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSColor(calibratedRed: 0.18, green: 0.74, blue: 0.84, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 420, y: 90, width: 130, height: 130)).fill()
        NSColor(calibratedRed: 0.64, green: 0.38, blue: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 62, y: 82, width: 240, height: 150),
                     xRadius: 22, yRadius: 22).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 34),
            .foregroundColor: NSColor.white
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)
        ]
        ("MNEMOSYNE" as NSString).draw(at: NSPoint(x: 82, y: 250), withAttributes: titleAttrs)
        (label as NSString).draw(in: NSRect(x: 82, y: 206, width: 470, height: 34), withAttributes: bodyAttrs)
        ("local knowledge test card" as NSString).draw(at: NSPoint(x: 82, y: 164), withAttributes: bodyAttrs)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func sampleImageURLs(count: Int) throws -> (directory: URL, urls: [URL]) {
        let dir = try tempDirectory(prefix: "MnemoImages")
        let urls = try (0..<count).map { i in
            let url = dir.appendingPathComponent("sample-\(i + 1).png")
            try samplePNGData(label: "generated sample \(i + 1)").write(to: url)
            return url
        }
        return (dir, urls)
    }

    static func writeTextPDF(_ string: String, to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        (string as NSString).draw(at: NSPoint(x: 72, y: 700),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        try data.write(to: url)
    }

    /// An isolated SettingsStore for tests (multimodal off so no Gemma calls).
    static func settings(multimodal: Bool = false, autoTag: Bool = true,
                         visionEngine: VisionEngine = .gemma) -> SettingsStore {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "MnemoTest-\(UUID().uuidString)")!)
        s.multimodal = multimodal
        s.autoTag = autoTag
        s.visionEngine = visionEngine
        return s
    }
}
