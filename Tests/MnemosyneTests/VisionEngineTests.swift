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
        // Clamped to the sane 16k–1M range (the models now support a 1M window).
        SettingsStore(defaults: d).contextBudget = 5_000
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, 16_000)
        SettingsStore(defaults: d).contextBudget = 512_000
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, 512_000, "512K is now within range")
        SettingsStore(defaults: d).contextBudget = 5_000_000
        XCTAssertEqual(SettingsStore(defaults: d).contextBudget, 1_000_000, "clamped to the 1M ceiling")
    }

    // MARK: ingest auto-fallback ordering

    func testNormalizedOrderDedupesAndNeverEmpty() {
        XCTAssertEqual(VisionEngine.normalizedOrder([.gemma, .claudeCode, .gemma, .codex, .claudeCode]),
                       [.gemma, .claudeCode, .codex], "duplicates dropped, first position kept")
        XCTAssertEqual(VisionEngine.normalizedOrder([]), [.gemma], "empty defaults to the safe local engine")
        XCTAssertEqual(VisionEngine.normalizedOrder([.codex, .gemma]), [.codex, .gemma], "order preserved")
    }

    func testEncodeDecodeRoundTrips() {
        let order: [VisionEngine] = [.claudeCode, .gemma]
        let encoded = VisionEngine.encodeOrder(order)
        XCTAssertEqual(encoded, "claudeCode,gemma")
        XCTAssertEqual(VisionEngine.decodeOrder(encoded), order)
        // Empty / garbage → [] so callers can supply their own default.
        XCTAssertTrue(VisionEngine.decodeOrder("").isEmpty)
        XCTAssertTrue(VisionEngine.decodeOrder("nonsense,more-nonsense").isEmpty)
        XCTAssertEqual(VisionEngine.decodeOrder("gemma,gemma,codex"), [.gemma, .codex], "decode also dedupes")
    }

    func testVisionEngineOrderPersistsAndSyncsPrimary() {
        let d = freshDefaults()
        let a = SettingsStore(defaults: d)
        a.visionEngineOrder = [.claudeCode, .gemma]
        let b = SettingsStore(defaults: d)
        XCTAssertEqual(b.visionEngineOrder, [.claudeCode, .gemma], "ordered preference round-trips")
        XCTAssertEqual(b.visionEngine, .claudeCode, "legacy primary stays in sync with the first entry")
    }

    func testVisionEngineOrderFallsBackToLegacySingleEngine() {
        // A user upgrading in place has only the old single-engine key set.
        let d = freshDefaults()
        d.set("codex", forKey: "mnemosyne.visionEngine")
        let settings = SettingsStore(defaults: d)
        XCTAssertEqual(settings.visionEngineOrder, [.codex], "derives the order from the legacy setting")
    }

    func testVisionEngineOrderStoresEnabledSubset() {
        // Selection: the user enables only Gemma + Claude (Codex disabled) — the order
        // persists exactly that subset, in priority order, and never pads to all engines.
        let d = freshDefaults()
        let a = SettingsStore(defaults: d)
        a.visionEngineOrder = [.gemma, .claudeCode]
        XCTAssertEqual(SettingsStore(defaults: d).visionEngineOrder, [.gemma, .claudeCode],
                       "only the enabled engines are stored, in order")
    }

    func testBuildEngineExternalCliClassification() {
        XCTAssertFalse(BuildEngine.deepseek.usesExternalCLI, "DeepSeek is native — no CLI")
        XCTAssertTrue(BuildEngine.claude.usesExternalCLI)
        XCTAssertTrue(BuildEngine.codex.usesExternalCLI)
        for e in BuildEngine.allCases { XCTAssertFalse(e.label.isEmpty); XCTAssertFalse(e.detail.isEmpty) }
    }
}
