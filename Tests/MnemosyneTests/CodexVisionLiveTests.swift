import XCTest
@testable import Mnemosyne

/// LIVE end-to-end check that the `codex` CLI vision path works through the real
/// app code. It spends a real Codex/OpenAI call, so it is opt-in:
///   MNEMO_LIVE_CODEX=1 swift test --filter CodexVisionLiveTests
final class CodexVisionLiveTests: XCTestCase {

    func testCodexDescribesARealImage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_CODEX"] == "1",
                          "set MNEMO_LIVE_CODEX=1 to run this quota-spending live test")
        try XCTSkipUnless(CodexCliClient.isAvailable, "codex CLI not found")

        let caption = await CodexCliClient.describe(pngData: TestSupport.samplePNGData())
        print("CODEX_CAPTION>>> \(caption ?? "<nil>")")
        let text = try XCTUnwrap(caption, "codex CLI should return a description")
        XCTAssertGreaterThan(text.count, 20, "description should be substantial")
    }

    func testCodexEngineReadsAPdfThroughExtractor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MNEMO_LIVE_CODEX"] == "1",
                          "set MNEMO_LIVE_CODEX=1 to run this quota-spending live test")
        try XCTSkipUnless(CodexCliClient.isAvailable, "codex CLI not found")
        let dir = try TestSupport.tempDirectory(prefix: "CodexPDF")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("sample.pdf")
        try TestSupport.writeTextPDF("Mnemosyne generated PDF fixture for Codex CLI extraction", to: pdf)

        let extractor = ContentExtractor(ollama: OllamaClient(config: .load()),
                                         multimodal: true, visionEngine: .codex)
        let text = try await extractor.extract(url: pdf, kind: .pdf)
        print("CODEX_PDF>>> \(text.prefix(160))")
        XCTAssertGreaterThan(text.count, 40, "Codex should extract substantial PDF content")
    }
}
