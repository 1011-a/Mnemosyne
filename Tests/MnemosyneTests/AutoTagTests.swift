import XCTest
@testable import Mnemosyne

final class AutoTagTests: XCTestCase {

    func testNormalize() {
        XCTAssertEqual(AutoTagger.normalize("My Project"), "my-project")
        XCTAssertEqual(AutoTagger.normalize("AI_Research"), "ai-research")
        XCTAssertEqual(AutoTagger.normalize("Notes-2024"), "notes-2024")
        XCTAssertNil(AutoTagger.normalize("2024"), "pure-numeric rejected")
        XCTAssertNil(AutoTagger.normalize("x"), "single char rejected")
        XCTAssertNil(AutoTagger.normalize("!!!"), "no letters rejected")
    }

    func testTagsFromFolderStructure() {
        let url = URL(fileURLWithPath: "/Users/alice/Projects/Atlas/notes.md")
        let tags = AutoTagger.tags(for: url)
        XCTAssertEqual(tags, ["atlas", "projects"], "deepest-first, stopwords removed")
    }

    func testStopwordsAndHomeStripped() {
        let url = URL(fileURLWithPath: "/Users/bob/Documents/file.txt")
        // Documents + Users + username(bob) are stopwords/skipped → no useful tags.
        XCTAssertTrue(AutoTagger.tags(for: url).allSatisfy { $0 != "documents" && $0 != "users" })
    }

    func testCapsAtMax() {
        let url = URL(fileURLWithPath: "/a/Work/Clients/Acme/Q3/Reports/file.pdf")
        XCTAssertEqual(AutoTagger.tags(for: url, max: 2).count, 2)
    }

    @MainActor
    func testIngestAutoTagsNewItems() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AutoTag-\(UUID().uuidString)/ProjectAlpha", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        try "Notes about vector databases and embeddings.".write(
            to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let dbDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoTagDB-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dbDir)
        let ingestor = Ingestor(store: store, embedder: embedder,
                                ollama: OllamaClient(config: .load()),
                                settings: TestSupport.settings(autoTag: true))
        let progress = IngestProgress()
        await ingestor.ingestFolder(root, progress: progress)

        XCTAssertEqual(progress.added, 1)
        let items = try await store.allItems()
        let id = try XCTUnwrap(items.first?.id)
        let tags = try await store.tags(forItem: id)
        XCTAssertTrue(tags.contains("projectalpha"), "should auto-tag from parent folder; got \(tags)")
    }
}
