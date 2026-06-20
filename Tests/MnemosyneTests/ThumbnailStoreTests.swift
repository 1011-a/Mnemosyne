import XCTest
import AppKit
@testable import Mnemosyne

@MainActor
final class ThumbnailStoreTests: XCTestCase {

    private func writePNG(to url: URL) throws {
        let img = NSImage(size: NSSize(width: 100, height: 100))
        img.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: url)
    }

    private func item(_ id: String, path: String, kind: ItemKind) -> KnowledgeItem {
        KnowledgeItem(id: id, path: path, title: id, kind: kind, contentHash: id,
                      byteSize: 0, createdAt: Date(), modifiedAt: Date())
    }

    func testLoadsAndCachesImageThumbnail() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Th-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.png")
        try writePNG(to: url)

        let store = ThumbnailStore()
        XCTAssertNil(store.cached("a"))
        await store.load(item("a", path: url.path, kind: .image))
        XCTAssertNotNil(store.cached("a"), "image thumbnail cached after load")
    }

    func testNonVisualKindNotCached() async throws {
        let store = ThumbnailStore()
        await store.load(item("t", path: "/tmp/x.txt", kind: .text))
        XCTAssertNil(store.cached("t"))
    }

    func testInvalidateDropsCache() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Th2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.png")
        try writePNG(to: url)

        let store = ThumbnailStore()
        await store.load(item("a", path: url.path, kind: .image))
        XCTAssertNotNil(store.cached("a"))
        store.invalidate("a")
        XCTAssertNil(store.cached("a"))
    }
}
