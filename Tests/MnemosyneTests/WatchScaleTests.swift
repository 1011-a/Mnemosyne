import XCTest
@testable import Mnemosyne

final class WatchScaleTests: XCTestCase {

    private func store() throws -> (KnowledgeStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoWS-\(UUID().uuidString)", isDirectory: true)
        return (try KnowledgeStore(directory: dir), dir)
    }

    func testSearchCapsChunksPerItem() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }

        // One "fat" file with many near-identical chunks, one small file.
        let fat = KnowledgeItem(id: "fat", path: "/tmp/fat.md", title: "fat.md", kind: .markdown,
                                contentHash: "f", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        let fatChunks = (0..<10).map { i in
            Chunk(id: "fat#\(i)", itemID: "fat", ordinal: i,
                  text: "vector embeddings nearest neighbor search \(i)",
                  embedding: embedder.embed("vector embeddings nearest neighbor search"))
        }
        try await store.upsert(item: fat, chunks: fatChunks)
        let small = KnowledgeItem(id: "small", path: "/tmp/small.md", title: "small.md", kind: .markdown,
                                  contentHash: "s", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        try await store.upsert(item: small, chunks: [
            Chunk(id: "small#0", itemID: "small", ordinal: 0,
                  text: "vector embedding similarity retrieval",
                  embedding: embedder.embed("vector embedding similarity retrieval"))
        ])

        let hits = try await store.search(vector: embedder.embed("embedding nearest neighbor"),
                                          k: 8, maxPerItem: 2)
        let fatCount = hits.filter { $0.item.id == "fat" }.count
        XCTAssertLessThanOrEqual(fatCount, 2, "one file must not dominate results")
        XCTAssertTrue(hits.contains { $0.item.id == "small" }, "the other file should surface too")
    }

    func testDeleteItemsCascadesChunks() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = KnowledgeItem(id: "d", path: "/tmp/d.md", title: "d.md", kind: .markdown,
                                 contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        try await store.upsert(item: item, chunks: [
            Chunk(id: "d#0", itemID: "d", ordinal: 0, text: "hello world", embedding: embedder.embed("hello world"))
        ])
        let before = try await store.chunkCount()
        XCTAssertEqual(before, 1)

        try await store.deleteItems(ids: ["d"])
        let items = try await store.itemCount()
        let chunks = try await store.chunkCount()
        XCTAssertEqual(items, 0)
        XCTAssertEqual(chunks, 0, "chunks must cascade-delete with their item")
    }

    func testPruneDeletedRemovesVanishedFiles() async throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "NLEmbedding unavailable")
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real file on disk + a phantom that doesn't exist.
        let real = dir.appendingPathComponent("real.txt")
        try "real content here".write(to: real, atomically: true, encoding: .utf8)
        let realItem = KnowledgeItem(id: "r", path: real.path, title: "real.txt", kind: .text,
                                     contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        let phantom = KnowledgeItem(id: "p", path: "/tmp/does-not-exist-\(UUID()).txt", title: "ghost", kind: .text,
                                    contentHash: "h", byteSize: 0, createdAt: Date(), modifiedAt: Date())
        try await store.upsert(item: realItem, chunks: [Chunk(id: "r#0", itemID: "r", ordinal: 0, text: "x", embedding: embedder.embed("x"))])
        try await store.upsert(item: phantom, chunks: [Chunk(id: "p#0", itemID: "p", ordinal: 0, text: "y", embedding: embedder.embed("y"))])

        let ingestor = Ingestor(store: store, embedder: embedder,
                                ollama: OllamaClient(config: .load()), settings: TestSupport.settings())
        let pruned = await ingestor.pruneDeleted()
        XCTAssertEqual(pruned, 1)
        let remaining = try await store.allItems().map(\.id)
        XCTAssertEqual(remaining, ["r"])
    }

    func testFolderWatcherFiresOnChange() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MnemoWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fired = expectation(description: "watcher reports a change")
        let box = Locked()
        let watcher = FolderWatcher(debounce: 0.4) { paths in
            if !paths.isEmpty, box.fireOnce() { fired.fulfill() }
        }
        watcher.start(paths: [dir])
        // Give FSEvents a beat to arm, then write a file.
        try await Task.sleep(nanoseconds: 300_000_000)
        try "new file".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        await fulfillment(of: [fired], timeout: 8.0)
        watcher.stop()
    }
}

/// Tiny thread-safe one-shot latch so the FSEvents callback fulfills once.
final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fireOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }; done = true; return true
    }
}
