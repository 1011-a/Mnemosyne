import XCTest
@testable import Mnemosyne

final class ArtifactStoreTests: XCTestCase {

    func testTitleFromFolderNameStripsTimestamp() {
        XCTAssertEqual(ArtifactStore.title(from: "1718900000-my-cool-dashboard"), "My Cool Dashboard")
        XCTAssertEqual(ArtifactStore.title(from: "vector-search-report"), "Vector Search Report")
        XCTAssertEqual(ArtifactStore.title(from: "1718900000-artifact"), "Artifact")
    }

    func testListsArtifactFoldersNewestFirst() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Artifacts-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Two artifact folders with files, one empty (ignored), one dotfile (ignored).
        let a = dir.appendingPathComponent("100-alpha-report")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try "<html></html>".write(to: a.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let b = dir.appendingPathComponent("200-beta-dashboard")
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try "x".write(to: b.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.appendingPathComponent("300-empty"), withIntermediateDirectories: true)

        let list = ArtifactStore.all(in: dir.path)
        XCTAssertEqual(list.count, 2, "empty folder is skipped")
        XCTAssertTrue(list.contains { $0.title == "Alpha Report" && $0.mainFile == "index.html" })
        XCTAssertTrue(list.contains { $0.title == "Beta Dashboard" && $0.mainFile == "data.csv" })
    }

    func testFindResolvesExactThenSubstring() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Find-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for slug in ["1-sales-dashboard", "2-sales-report"] {
            let f = dir.appendingPathComponent(slug)
            try fm.createDirectory(at: f, withIntermediateDirectories: true)
            try "x".write(to: f.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        }
        let arts = ArtifactStore.all(in: dir.path)
        XCTAssertEqual(ArtifactStore.find("Sales Report", in: arts)?.title, "Sales Report", "exact wins")
        XCTAssertEqual(ArtifactStore.find("dashboard", in: arts)?.title, "Sales Dashboard", "substring")
        XCTAssertNil(ArtifactStore.find("nonexistent", in: arts))
        XCTAssertNil(ArtifactStore.find("  ", in: arts))
    }

    func testMissingDirectoryGivesEmpty() {
        XCTAssertTrue(ArtifactStore.all(in: "/no/such/dir-\(UUID().uuidString)").isEmpty)
    }

    func testExportFileNameStripsUnsafeCharacters() {
        XCTAssertEqual(ArtifactStore.exportFileName("My Report"), "My Report")
        XCTAssertEqual(ArtifactStore.exportFileName("a/b:c?d"), "a b c d")
        XCTAssertEqual(ArtifactStore.exportFileName("///"), "Artifact", "all-unsafe ⇒ fallback name")
    }

    func testExportZipsArtifactToDestination() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folder = root.appendingPathComponent("100-share-me")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<html>hi</html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let artifact = ArtifactStore.all(in: root.path).first
        let a = try XCTUnwrap(artifact)

        let dest = root.appendingPathComponent("out").path
        let zip = try XCTUnwrap(ArtifactStore.export(a, toDirectory: dest), "export should return a zip path")
        XCTAssertTrue(zip.hasSuffix("Share Me.zip"))
        XCTAssertTrue(fm.fileExists(atPath: zip))
        let size = (try fm.attributesOfItem(atPath: zip)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "the zip is non-empty")
    }
}
