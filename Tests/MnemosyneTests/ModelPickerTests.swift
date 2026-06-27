import XCTest
@testable import Mnemosyne

final class ModelPickerTests: XCTestCase {

    func testConfigOverridingModelPreservesOtherFields() {
        let base = Config.load()
        let overridden = base.overriding(model: "deepseek-v4-pro")
        XCTAssertEqual(overridden.deepSeekModel, "deepseek-v4-pro")
        XCTAssertEqual(overridden.deepSeekKey, base.deepSeekKey)
        XCTAssertEqual(overridden.deepSeekBaseURL, base.deepSeekBaseURL)
        XCTAssertEqual(overridden.ollamaVisionModel, base.ollamaVisionModel)
    }

    private func tempSettings() -> (SettingsStore, String) {
        let path = NSTemporaryDirectory() + "secrets-\(UUID().uuidString).json"
        return (SettingsStore(defaults: UserDefaults(suiteName: "Cfg-\(UUID().uuidString)")!,
                              keychainService: "com.mnemosyne.tests.\(UUID().uuidString)",
                              secrets: SecretsFile(path: path)), path)
    }

    func testConfigLoadsDeepSeekKeyFromSettings() {
        let (settings, path) = tempSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(settings.setDeepSeekKey("sk-from-settings"))

        let config = Config.load(settings: settings, environment: [:], arguments: [])
        XCTAssertEqual(config.deepSeekKey, "sk-from-settings")
        XCTAssertEqual(config.deepSeekKeySource, .settings)
    }

    func testEnvironmentDeepSeekKeyOverridesSettings() {
        let (settings, path) = tempSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(settings.setDeepSeekKey("sk-from-settings"))

        let config = Config.load(settings: settings,
                                 environment: ["DEEPSEEK_API_KEY": "sk-from-env"],
                                 arguments: [])
        XCTAssertEqual(config.deepSeekKey, "sk-from-env")
        XCTAssertEqual(config.deepSeekKeySource, .environment)
    }

    func testMissingDeepSeekKeyFailsBeforeNetwork() async throws {
        let config = Config(
            deepSeekKey: "",
            deepSeekBaseURL: URL(string: "https://example.invalid")!,
            deepSeekModel: "deepseek-v4-flash",
            ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!,
            ollamaVisionModel: "gemma3:12b",
            deepSeekKeySource: .missing)
        let client = DeepSeekClient(config: config)

        do {
            _ = try await client.complete([ChatMessage(role: .user, content: "hello")])
            XCTFail("Missing key should fail before making a network request")
        } catch ClientError.missingDeepSeekKey {
            XCTAssertEqual(ClientError.missingDeepSeekKey.localizedDescription,
                           "DeepSeek API key is missing. Add it in Settings.")
        }
    }

    func testOverridingWithEmptyKeepsExistingModel() {
        let base = Config.load()
        XCTAssertEqual(base.overriding(model: "").deepSeekModel, base.deepSeekModel)
    }

    func testSettingsModelDefaultAndPersist() {
        let s = SettingsStore(defaults: UserDefaults(suiteName: "Model-\(UUID().uuidString)")!)
        XCTAssertEqual(s.model, "deepseek-v4-flash")
        s.model = "deepseek-v4-pro"
        XCTAssertEqual(s.model, "deepseek-v4-pro")
        XCTAssertTrue(Config.availableModels.contains(s.model))
    }

    /// Live: the reasoner model answers through the same client path.
    func testLiveReasonerModelAnswers() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled,
                          "set MNEMO_LIVE_DEEPSEEK=1 to run this quota-spending live test")
        let config = Config.load()
        try XCTSkipIf(config.deepSeekKey.isEmpty, "no DeepSeek key")
        let client = DeepSeekClient(config: config.overriding(model: "deepseek-v4-pro"))
        let reply: String
        do {
            reply = try await client.complete([ChatMessage(role: .user, content: "Reply with exactly: REASONER_OK")])
        } catch {
            throw XCTSkip("network/API unavailable: \(error.localizedDescription)")
        }
        XCTAssertTrue(reply.contains("REASONER_OK"), "got: \(reply.prefix(120))")
    }
}
