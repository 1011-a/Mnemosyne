import XCTest
@testable import Mnemosyne

final class IngestCapTests: XCTestCase {

    /// A pathologically large text file must be capped (so one big file can't
    /// stall the queue) — but still ingest a useful, non-empty portion.
    func testHugeFileIsCappedToMaxChunks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // ~6 MB of text → far more than maxChunks worth of chunks.
        let big = dir.appendingPathComponent("huge.txt")
        try String(repeating: "Sentence number one is right here in the file. ", count: 130_000)
            .write(to: big, atomically: true, encoding: .utf8)

        let store = try KnowledgeStore(directory: dir.appendingPathComponent("db"))
        let ingestor = await Ingestor(store: store, embedder: Embedder(),
                                      ollama: OllamaClient(config: .load()),
                                      settings: TestSupport.settings())
        await ingestor.ingest(urls: [big], progress: await IngestProgress())

        let chunkCount = try await store.chunkCount()
        let itemCount = try await store.itemCount()
        XCTAssertGreaterThan(chunkCount, 0, "still ingests a useful portion")
        XCTAssertLessThanOrEqual(chunkCount, Ingestor.maxChunks, "capped so it can't stall the queue")
        XCTAssertEqual(itemCount, 1)
    }
}
