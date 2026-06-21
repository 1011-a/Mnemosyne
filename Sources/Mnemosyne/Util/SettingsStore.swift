import Foundation

/// The scene shown in the Ingest "Live activity" panel — user-selectable.
enum LiveActivityTheme: String, CaseIterable, Sendable, Identifiable {
    /// Retro pixel skyline whose windows light up as files index (the original).
    case pixelCity
    /// A warm starry night: stars light up with activity over a family stargazing.
    case starrySky

    var id: String { rawValue }
    var label: String {
        switch self {
        case .pixelCity: return "Knowledge City"
        case .starrySky: return "Starry Night"
        }
    }
    var icon: String {
        switch self {
        case .pixelCity: return "building.2.fill"
        case .starrySky: return "sparkles"
        }
    }
}

/// Which engine performs image / scanned-PDF visual understanding during ingest.
enum VisionEngine: String, CaseIterable, Sendable, Identifiable, Hashable {
    /// Local Gemma 3 12B via Ollama — private, on-device, default.
    case gemma
    /// The locally-installed `claude` CLI (the user's own Claude Code login) —
    /// richer descriptions, no API key, but uses Claude usage quota and is not
    /// faster than (downscaled) Gemma. Opt-in.
    case claudeCode
    /// The locally-installed `codex` CLI (the user's own Codex/OpenAI login).
    /// Uses Codex's multimodal model path and read-only file inspection.
    case codex

    var id: String { rawValue }
    var label: String {
        switch self {
        case .gemma:      return "Gemma 12B — local & private"
        case .claudeCode: return "Claude Code CLI — best quality"
        case .codex:      return "Codex CLI — OpenAI"
        }
    }
    var detail: String {
        switch self {
        case .gemma:      return "Images & scanned PDF pages, entirely on your Mac. Nothing leaves the device."
        case .claudeCode: return "Reads images AND whole PDFs/documents via your installed claude CLI (no API key). Best quality; spends Claude quota; ~same speed as Gemma per file."
        case .codex:      return "Reads images and whole PDFs/documents via your installed codex CLI. Uses your Codex login/default model; spends Codex/OpenAI quota."
        }
    }

    var activityName: String {
        switch self {
        case .gemma:      return "Gemma"
        case .claudeCode: return "Claude"
        case .codex:      return "Codex"
        }
    }

    var usesExternalCLI: Bool {
        switch self {
        case .gemma: return false
        case .claudeCode, .codex: return true
        }
    }

    /// Clean an ordered engine preference list: drop duplicates (keeping first
    /// position), and guarantee a non-empty result (default `[.gemma]`). Pure →
    /// unit-testable. Backs the ingest auto-fallback ("try Gemma, then Claude").
    static func normalizedOrder(_ order: [VisionEngine]) -> [VisionEngine] {
        var seen = Set<VisionEngine>()
        let deduped = order.filter { seen.insert($0).inserted }
        return deduped.isEmpty ? [.gemma] : deduped
    }

    /// Serialize an order to a stable string for UserDefaults ("gemma,claudeCode").
    static func encodeOrder(_ order: [VisionEngine]) -> String {
        normalizedOrder(order).map(\.rawValue).joined(separator: ",")
    }

    /// Parse an order string back; empty/garbage yields `[]` so the caller can supply
    /// its own default (e.g. the legacy single-engine setting).
    static func decodeOrder(_ raw: String) -> [VisionEngine] {
        let parsed = raw.split(separator: ",").compactMap { VisionEngine(rawValue: String($0)) }
        var seen = Set<VisionEngine>()
        return parsed.filter { seen.insert($0).inserted }   // [] when nothing valid parsed
    }
}

/// Which CLI developer-agent builds artifacts for `create_artifact`.
enum BuildEngine: String, CaseIterable, Sendable, Identifiable {
    /// DeepSeek builds the artifact itself (native, no external CLI) — the default.
    /// claude/codex delegate to those developer CLIs when you prefer them.
    case deepseek, claude, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .deepseek: return "DeepSeek (native)"
        case .claude:   return "Claude Code"
        case .codex:    return "Codex"
        }
    }
    var detail: String {
        switch self {
        case .deepseek: return "Built directly by DeepSeek — no external CLI required."
        case .claude:   return "Delegates to the Claude Code CLI (must be installed)."
        case .codex:    return "Delegates to the Codex CLI (must be installed)."
        }
    }
    /// DeepSeek is always usable (it's the agent brain); the CLIs need to be installed.
    var usesExternalCLI: Bool { self != .deepseek }
}

/// User-tunable knobs, persisted in UserDefaults. Read at launch into `Services`
/// and threaded into the agent/extractor.
// UserDefaults is thread-safe; vouch for it so the multimodal provider closure
// can read settings live from any actor.
struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychainService: String
    private let secrets: SecretsFile
    init(defaults: UserDefaults = .standard,
         keychainService: String = "com.mnemosyne.app",
         secrets: SecretsFile = SecretsFile()) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.secrets = secrets
    }

    private enum Key {
        static let topK = "mnemosyne.topK"
        static let temperature = "mnemosyne.temperature"
        static let multimodal = "mnemosyne.multimodal"
        static let queryRewrite = "mnemosyne.queryRewrite"
        static let agentic = "mnemosyne.agentic"
        static let agenticCritic = "mnemosyne.agenticCritic"
        static let autoTag = "mnemosyne.autoTag"
        static let model = "mnemosyne.model"
        static let keywordWeight = "mnemosyne.keywordWeight"
        static let visionEngine = "mnemosyne.visionEngine"
        static let visionEngineOrder = "mnemosyne.visionEngineOrder"
        static let buildEngine = "mnemosyne.buildEngine"
        static let contextBudget = "mnemosyne.contextBudget"
        static let liveActivityTheme = "mnemosyne.liveActivityTheme"
    }

    /// Which scene the Ingest "Live activity" panel shows. User-selectable.
    var liveActivityTheme: LiveActivityTheme {
        get { LiveActivityTheme(rawValue: defaults.string(forKey: Key.liveActivityTheme) ?? "") ?? .pixelCity }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.liveActivityTheme) }
    }

    /// Conversation context budget in tokens. NOT user-tunable: the agent handles its own
    /// context for the BEST quality, always using the full 1M-token window the models now
    /// support (history is kept verbatim; compaction only kicks in past 1M). One less knob
    /// for the user to think about.
    static let maxContextBudget = 1_000_000
    var contextBudget: Int { Self.maxContextBudget }

    /// Which engine builds artifacts (create_artifact). Defaults to DeepSeek-native.
    var buildEngine: BuildEngine {
        get { BuildEngine(rawValue: defaults.string(forKey: Key.buildEngine) ?? "") ?? .deepseek }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.buildEngine) }
    }
    private enum SecretAccount {
        static let deepSeekKey = "deepseek.apiKey"
        static let serpApiKey = "serpapi.apiKey"
    }

    /// DeepSeek API key, stored in a plain config file (Application Support) — not
    /// the Keychain, which prompted for permission on nearly every read.
    var deepSeekKey: String {
        get { secret(SecretAccount.deepSeekKey) }
        nonmutating set { _ = setDeepSeekKey(newValue) }
    }

    @discardableResult
    nonmutating func setDeepSeekKey(_ key: String) -> Bool {
        secrets.write(SecretAccount.deepSeekKey, key)
    }

    /// Optional SerpAPI key for richer web search. Empty ⇒ keyless fallback is used.
    var serpApiKey: String {
        get { secret(SecretAccount.serpApiKey) }
        nonmutating set { secrets.write(SecretAccount.serpApiKey, newValue) }
    }

    /// Read a secret from the file, with a ONE-TIME migration from the old Keychain
    /// entry (so existing users keep their key). Reading a non-existent Keychain item
    /// doesn't prompt; only a pre-existing key triggers a single migration prompt.
    private func secret(_ account: String) -> String {
        if let v = secrets.read(account) { return v }
        // One-time migration: copy a pre-existing Keychain key into the file, then
        // DELETE it from the Keychain so it's never read (or prompted for) again — and
        // so clearing the file key actually clears it (no stale Keychain fallback).
        if !secrets.migrated(account),
           let legacy = KeychainStore.read(service: keychainService, account: account), !legacy.isEmpty {
            secrets.write(account, legacy)
            KeychainStore.delete(service: keychainService, account: account)
            return legacy
        }
        return ""
    }

    /// Engine used for image / scanned-PDF understanding during ingest. This is the
    /// PRIMARY engine — it mirrors the first entry of `visionEngineOrder`.
    var visionEngine: VisionEngine {
        get { VisionEngine(rawValue: defaults.string(forKey: Key.visionEngine) ?? "") ?? .gemma }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.visionEngine) }
    }

    /// Ordered ingest-engine preference with AUTO-FALLBACK: try the first engine; if it
    /// fails, times out, or returns nothing, the extractor falls through to the next
    /// (e.g. [Gemma, Claude] → Gemma first, Claude on failure). Always non-empty. Setting
    /// it keeps the legacy `visionEngine` in sync with the primary (first) entry.
    var visionEngineOrder: [VisionEngine] {
        get {
            let parsed = VisionEngine.decodeOrder(defaults.string(forKey: Key.visionEngineOrder) ?? "")
            // Fall back to the legacy single-engine setting for users upgrading in place.
            return VisionEngine.normalizedOrder(parsed.isEmpty ? [visionEngine] : parsed)
        }
        nonmutating set {
            let norm = VisionEngine.normalizedOrder(newValue)
            defaults.set(VisionEngine.encodeOrder(norm), forKey: Key.visionEngineOrder)
            if let primary = norm.first { visionEngine = primary }   // keep legacy key in sync
        }
    }

    /// Hybrid search: how much the exact-keyword overlap boosts the vector score
    /// (0 = pure semantic, higher = exact terms matter more). Default 0.3.
    var keywordWeight: Double {
        get { defaults.object(forKey: Key.keywordWeight) as? Double ?? 0.3 }
        nonmutating set { defaults.set(min(1.0, max(0, newValue)), forKey: Key.keywordWeight) }
    }

    /// Which DeepSeek model the agent brain uses (chat vs reasoner).
    var model: String {
        get { defaults.string(forKey: Key.model) ?? "deepseek-chat" }
        nonmutating set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Auto-tag new items from their folder structure on ingest. Default on.
    var autoTag: Bool {
        get { defaults.object(forKey: Key.autoTag) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.autoTag) }
    }

    /// Agentic mode: DeepSeek drives a multi-hop tool-calling search loop instead
    /// of one-shot RAG. Default on — it's the headline "Agent Brain" experience.
    var agentic: Bool {
        get { defaults.object(forKey: Key.agentic) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.agentic) }
    }

    /// Critic pass: a reviewer verifies the gathered evidence before the agent
    /// answers (can trigger one more search or force the answer to hedge). Default on.
    var agenticCritic: Bool {
        get { defaults.object(forKey: Key.agenticCritic) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.agenticCritic) }
    }

    var topK: Int {
        get { defaults.object(forKey: Key.topK) as? Int ?? 8 }
        nonmutating set { defaults.set(min(20, max(1, newValue)), forKey: Key.topK) }
    }
    var temperature: Double {
        get { defaults.object(forKey: Key.temperature) as? Double ?? 0.3 }
        nonmutating set { defaults.set(min(1.0, max(0, newValue)), forKey: Key.temperature) }
    }
    var multimodal: Bool {
        get { defaults.object(forKey: Key.multimodal) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.multimodal) }
    }
    var queryRewrite: Bool {
        get { defaults.object(forKey: Key.queryRewrite) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.queryRewrite) }
    }
}
