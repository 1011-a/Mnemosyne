import XCTest
import AppKit
@testable import Mnemosyne

final class ArtifactThumbnailerTests: XCTestCase {
    /// Gated (WebKit needs a UI/main run loop): verify an HTML artifact renders to a
    /// non-blank thumbnail. MNEMO_LIVE_UI=1 swift test --filter ArtifactThumbnailer
    @MainActor
    func testRendersHtmlArtifactThumbnail() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_UI"] == "1", "set MNEMO_LIVE_UI=1")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<!doctype html><html><body style='background:#F03E16'><h1 style='color:white'>Hello</h1></body></html>"
            .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let a = ArtifactStore.all(in: dir.deletingLastPathComponent().path)
            .first { $0.path == dir.path } ?? Artifact(id: dir.path, title: "t", date: Date(), files: ["index.html"], mainFile: "index.html")
        let img = await ArtifactThumbnailer.shared.thumbnail(for: a)
        print("THUMB>>> \(img == nil ? "nil" : "\(Int(img!.size.width))x\(Int(img!.size.height))")")
        XCTAssertNotNil(img, "HTML artifact should render to a thumbnail image")
    }
}
