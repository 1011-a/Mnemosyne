import XCTest
@testable import Mnemosyne

/// LIVE end-to-end check that the `claude` CLI vision path actually works through
/// the real app code (Process plumbing, PATH, temp file, stdout parsing). It spends
/// a real Claude call, so it's opt-in: run with
///   MNEMO_LIVE_CLAUDE=1 swift test --filter ClaudeVisionLiveTests
final class ClaudeVisionLiveTests: XCTestCase {

    func testClaudeCodeDescribesARealImage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_CLAUDE"] == "1",
                          "set MNEMO_LIVE_CLAUDE=1 to run this quota-spending live test")
        try XCTSkipUnless(ClaudeCodeClient.isAvailable, "claude CLI not found")

        let caption = await ClaudeCodeClient.describe(pngData: TestSupport.samplePNGData())
        print("CLAUDE_CAPTION>>> \(caption ?? "<nil>")")
        let text = try XCTUnwrap(caption, "claude CLI should return a description")
        XCTAssertGreaterThan(text.count, 20, "description should be substantial")
    }

    /// The FULL document path: ContentExtractor with the Claude engine reads a
    /// real PDF end-to-end (proves rich documents — not just images — go through Claude).
    func testClaudeEngineReadsAPdfThroughExtractor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_CLAUDE"] == "1",
                          "set MNEMO_LIVE_CLAUDE=1 to run this quota-spending live test")
        try XCTSkipUnless(ClaudeCodeClient.isAvailable, "claude CLI not found")
        let dir = try TestSupport.tempDirectory(prefix: "ClaudePDF")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("sample.pdf")
        try TestSupport.writeTextPDF("Mnemosyne generated PDF fixture for Claude CLI extraction", to: pdf)

        let extractor = ContentExtractor(ollama: OllamaClient(config: .load()),
                                         multimodal: true, visionEngine: .claudeCode)
        let text = try await extractor.extract(url: pdf, kind: .pdf)
        print("CLAUDE_PDF>>> \(text.prefix(160))")
        XCTAssertGreaterThan(text.count, 40, "Claude should extract substantial PDF content")
    }

    /// The developer-agent "create" capability actually writes a deliverable file.
    func testClaudeCreateArtifactWritesFiles() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_CLAUDE"] == "1",
                          "set MNEMO_LIVE_CLAUDE=1 to run this quota-spending live test")
        try XCTSkipUnless(ClaudeCodeClient.isAvailable, "claude CLI not found")
        let dir = try TestSupport.tempDirectory(prefix: "Artifact")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await ClaudeCodeClient.createArtifact(
            task: "Create a single file report.html: a minimal valid HTML page titled 'Test' with an <h1>.",
            context: "(no sources)", workdir: dir.path, timeout: 180)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") } ?? []
        print("ARTIFACT_FILES>>> \(files)")
        XCTAssertFalse(files.isEmpty, "build agent should write at least one file")
    }

    /// End-to-end: the Ingestor runs Claude vision calls CONCURRENTLY, so a batch of
    /// images finishes far faster than serial (proves the speedup pipeline works).
    func testClaudeIngestRunsConcurrently() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_CLAUDE"] == "1",
                          "set MNEMO_LIVE_CLAUDE=1 to run this quota-spending live test")
        try XCTSkipUnless(ClaudeCodeClient.isAvailable, "claude CLI not found")
        let samples = try TestSupport.sampleImageURLs(count: 4)
        defer { try? FileManager.default.removeItem(at: samples.directory) }

        let dir = try TestSupport.tempDirectory(prefix: "ClaudeIngest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let ingestor = Ingestor(store: store, embedder: Embedder(),
                                ollama: OllamaClient(config: .load()),
                                settings: TestSupport.settings(multimodal: true, visionEngine: .claudeCode))
        let progress = await IngestProgress()

        let t0 = Date()
        await ingestor.ingest(urls: samples.urls, progress: progress)
        let elapsed = Date().timeIntervalSince(t0)
        print("CLAUDE_INGEST>>> \(samples.urls.count) images in \(String(format: "%.1f", elapsed))s")
        let added = await progress.added
        XCTAssertGreaterThan(added, 0, "should index the images")
        // Serial would be ~10s each (~40s for 4). Concurrency must beat that clearly.
        XCTAssertLessThan(elapsed, Double(samples.urls.count) * 9, "lanes must overlap, not run serially")
    }
}
