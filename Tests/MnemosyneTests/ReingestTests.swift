import XCTest
@testable import Mnemosyne

@MainActor
final class ReingestTests: XCTestCase {

    func testReingestPicksUpEditedContent() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reingest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "original content about cats".write(to: file, atomically: true, encoding: .utf8)

        let dbDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ReingestDB-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dbDir)
        let ingestor = Ingestor(store: store, embedder: embedder,
                                ollama: OllamaClient(config: .load()), settings: TestSupport.settings())

        await ingestor.ingest(urls: [file], progress: IngestProgress())
        let itemID = try await store.allItems().first!.id
        var chunks = try await store.chunkTexts(forItem: itemID)
        XCTAssertTrue(chunks.joined().contains("cats"))

        // Edit the file, then force re-ingest.
        try "completely new content about quantum computing".write(to: file, atomically: true, encoding: .utf8)
        await ingestor.reingest(path: file.path, progress: IngestProgress())

        chunks = try await store.chunkTexts(forItem: itemID)
        XCTAssertTrue(chunks.joined().contains("quantum"), "re-ingest should reflect edited content")
        XCTAssertFalse(chunks.joined().contains("cats"), "old content replaced")
        let count = try await store.itemCount()
        XCTAssertEqual(count, 1, "re-ingest updates in place, no duplicate")
    }

    func testReingestUnchangedStillReprocesses() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reingest2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "stable content here".write(to: file, atomically: true, encoding: .utf8)

        let dbDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Reingest2DB-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dbDir)
        let ingestor = Ingestor(store: store, embedder: embedder,
                                ollama: OllamaClient(config: .load()), settings: TestSupport.settings())
        await ingestor.ingest(urls: [file], progress: IngestProgress())

        // Unchanged file: force re-ingest processes it (added == 1, not skipped).
        let p = IngestProgress()
        await ingestor.reingest(path: file.path, progress: p)
        XCTAssertEqual(p.added, 1)
        XCTAssertEqual(p.skipped, 0)
    }
}
