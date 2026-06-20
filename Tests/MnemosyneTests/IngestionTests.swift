import XCTest
@testable import Mnemosyne

final class IngestionTests: XCTestCase {

    private func makeCorpus() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoCorpus-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try "Risotto needs warm stock added slowly with constant stirring until creamy."
            .write(to: root.appendingPathComponent("cooking.txt"), atomically: true, encoding: .utf8)
        try "# Vector Search\n\nFAISS and SQLite-vss index embeddings for nearest-neighbor retrieval over your notes."
            .write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0){$0+$1.0*$1.1} }"
            .write(to: root.appendingPathComponent("math.swift"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Budget</h1><p>Quarterly spend on cloud GPUs rose 12 percent.</p></body></html>"
            .write(to: root.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)

        // Noise that must be skipped:
        let nm = root.appendingPathComponent("node_modules", isDirectory: true)
        try fm.createDirectory(at: nm, withIntermediateDirectories: true)
        try "module.exports = {}".write(to: nm.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        return root
    }

    func testScannerSkipsNoise() throws {
        let root = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = FolderScanner.scan(root)
        let names = Set(urls.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["cooking.txt", "notes.md", "math.swift", "report.html"])
    }

    func testHTMLExtractionFlattens() async throws {
        let root = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let ex = ContentExtractor(ollama: OllamaClient(config: .load()), multimodal: false)
        let text = try await ex.extract(url: root.appendingPathComponent("report.html"), kind: .html)
        XCTAssertTrue(text.contains("Quarterly spend"))
        XCTAssertFalse(text.contains("<p>"), "HTML tags should be stripped")
    }

    @MainActor
    func testFullIngestIncrementalAndSearch() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable on host")

        let root = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoDB-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }

        let store = try KnowledgeStore(directory: dbDir)
        let ingestor = Ingestor(store: store, embedder: embedder,
                                ollama: OllamaClient(config: .load()), settings: TestSupport.settings())
        let progress = IngestProgress()

        await ingestor.ingestFolder(root, progress: progress)
        XCTAssertEqual(progress.added, 4)
        let count = try await store.itemCount()
        XCTAssertEqual(count, 4)

        // Semantic retrieval finds the right document.
        let hits = try await store.search(vector: embedder.embed("nearest neighbor embedding search"), k: 1)
        XCTAssertEqual(hits.first?.item.title, "notes.md")

        // Second pass: everything unchanged → all skipped, no new items.
        let progress2 = IngestProgress()
        await ingestor.ingestFolder(root, progress: progress2)
        XCTAssertEqual(progress2.added, 0)
        XCTAssertEqual(progress2.skipped, 4)
        let countAfter = try await store.itemCount()
        XCTAssertEqual(countAfter, 4)
    }
}
