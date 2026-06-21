import XCTest
@testable import Mnemosyne

final class VisionEngineTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "VisionEngineTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsToGemma() {
        let settings = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(settings.visionEngine, .gemma, "private local Gemma is the safe default")
    }

    func testVisionEnginePersists() {
        let defaults = freshDefaults()
        let a = SettingsStore(defaults: defaults)
        a.visionEngine = .claudeCode
        // A fresh store over the same defaults must read the saved choice back.
        let b = SettingsStore(defaults: defaults)
        XCTAssertEqual(b.visionEngine, .claudeCode)

        b.visionEngine = .codex
        let c = SettingsStore(defaults: defaults)
        XCTAssertEqual(c.visionEngine, .codex)
    }

    func testUnknownRawValueFallsBackToGemma() {
        let defaults = freshDefaults()
        defaults.set("some-old-removed-engine", forKey: "mnemosyne.visionEngine")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.visionEngine, .gemma, "an unknown stored value must not crash")
    }

    func testEveryEngineHasLabelAndDetail() {
        for eng in VisionEngine.allCases {
            XCTAssertFalse(eng.label.isEmpty)
            XCTAssertFalse(eng.detail.isEmpty)
            XCTAssertFalse(eng.activityName.isEmpty)
        }
    }

    func testExternalCliClassification() {
        XCTAssertFalse(VisionEngine.gemma.usesExternalCLI)
        XCTAssertTrue(VisionEngine.claudeCode.usesExternalCLI)
        XCTAssertTrue(VisionEngine.codex.usesExternalCLI)
    }

    func testBuildEngineDefaultsToDeepSeekAndPersists() {
        let d = freshDefaults()
        XCTAssertEqual(SettingsStore(defaults: d).buildEngine, .deepseek, "DeepSeek-native is the default")
        SettingsStore(defaults: d).buildEngine = .codex
        XCTAssertEqual(SettingsStore(defaults: d).buildEngine, .codex)
        d.set("nonsense", forKey: "mnemosyne.buildEngine")
        XCTAssertEqual(SettingsStore(defaults: d).buildEngine, .deepseek, "unknown value falls back to DeepSeek")
    }

    func testContextBudgetDefaultsAndClamps() {
        let d = freshDefaults()
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, ContextManager.defaultBudgetTokens, "generous default")
        SettingsStore(defaults: d).contextBudget = 64_000
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, 64_000)
        // Clamped to the sane 16k–128k range.
        SettingsStore(defaults: d).contextBudget = 5_000
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, 16_000)
        SettingsStore(defaults: d).contextBudget = 500_000
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, 128_000)
    }

    func testBuildEngineExternalCliClassification() {
        XCTAssertFalse(BuildEngine.deepseek.usesExternalCLI, "DeepSeek is native — no CLI")
        XCTAssertTrue(BuildEngine.claude.usesExternalCLI)
        XCTAssertTrue(BuildEngine.codex.usesExternalCLI)
        for e in BuildEngine.allCases { XCTAssertFalse(e.label.isEmpty); XCTAssertFalse(e.detail.isEmpty) }
    }
}
