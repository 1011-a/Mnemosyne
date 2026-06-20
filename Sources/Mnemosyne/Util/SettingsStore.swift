import Foundation

/// Which engine performs image / scanned-PDF visual understanding during ingest.
enum VisionEngine: String, CaseIterable, Sendable, Identifiable {
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
}

/// User-tunable knobs, persisted in UserDefaults. Read at launch into `Services`
/// and threaded into the agent/extractor.
// UserDefaults is thread-safe; vouch for it so the multimodal provider closure
// can read settings live from any actor.
struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychainService: String
    init(defaults: UserDefaults = .standard,
         keychainService: String = "com.mnemosyne.app") {
        self.defaults = defaults
        self.keychainService = keychainService
    }

    private enum Key {
        static let topK = "mnemosyne.topK"
        static let temperature = "mnemosyne.temperature"
        static let multimodal = "mnemosyne.multimodal"
        static let queryRewrite = "mnemosyne.queryRewrite"
        static let agentic = "mnemosyne.agentic"
        static let autoTag = "mnemosyne.autoTag"
        static let model = "mnemosyne.model"
        static let keywordWeight = "mnemosyne.keywordWeight"
        static let visionEngine = "mnemosyne.visionEngine"
    }
    private enum SecretAccount {
        static let deepSeekKey = "deepseek.apiKey"
    }

    /// DeepSeek API key, stored in macOS Keychain rather than UserDefaults.
    var deepSeekKey: String {
        get { KeychainStore.read(service: keychainService, account: SecretAccount.deepSeekKey) ?? "" }
        nonmutating set { _ = setDeepSeekKey(newValue) }
    }

    @discardableResult
    nonmutating func setDeepSeekKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeychainStore.save(trimmed, service: keychainService, account: SecretAccount.deepSeekKey)
    }

    /// Engine used for image / scanned-PDF understanding during ingest.
    var visionEngine: VisionEngine {
        get { VisionEngine(rawValue: defaults.string(forKey: Key.visionEngine) ?? "") ?? .gemma }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.visionEngine) }
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
