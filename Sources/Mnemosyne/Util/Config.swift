import Foundation

/// Loads app configuration. Secrets come from macOS Keychain by default, while
/// process environment variables and an explicit `MNEMOSYNE_ENV_PATH` can still
/// override values for development/testing.
struct Config: Sendable {
    enum DeepSeekKeySource: Sendable {
        case missing
        case settings
        case environment
    }

    let deepSeekKey: String
    let deepSeekBaseURL: URL
    let deepSeekModel: String
    let ollamaBaseURL: URL
    let ollamaVisionModel: String
    let deepSeekKeySource: DeepSeekKeySource

    /// Optional env file. There is intentionally no personal/default path here;
    /// users configure the DeepSeek key in Settings.
    static func envPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let p = environment["MNEMOSYNE_ENV_PATH"], !p.isEmpty else { return nil }
        return p
    }

    /// Known DeepSeek models the user can pick between.
    static let availableModels = ["deepseek-v4-flash", "deepseek-v4-pro"]

    /// A copy with the DeepSeek model swapped — lets agents pick a model live.
    func overriding(model: String) -> Config {
        Config(deepSeekKey: deepSeekKey, deepSeekBaseURL: deepSeekBaseURL,
               deepSeekModel: model.isEmpty ? deepSeekModel : model,
               ollamaBaseURL: ollamaBaseURL, ollamaVisionModel: ollamaVisionModel,
               deepSeekKeySource: deepSeekKeySource)
    }

    /// A copy with the DeepSeek key swapped from live Settings/Keychain.
    func overriding(deepSeekKey key: String) -> Config {
        let source: DeepSeekKeySource = deepSeekKeySource == .environment
            ? .environment
            : (key.isEmpty ? .missing : .settings)
        return Config(deepSeekKey: key, deepSeekBaseURL: deepSeekBaseURL,
                      deepSeekModel: deepSeekModel,
                      ollamaBaseURL: ollamaBaseURL, ollamaVisionModel: ollamaVisionModel,
                      deepSeekKeySource: source)
    }

    static func load(settings: SettingsStore = SettingsStore(),
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     arguments: [String] = ProcessInfo.processInfo.arguments) -> Config {
        // Under XCUITest (`--uitest`) don't read the Desktop env file — Desktop is
        // a TCC-protected folder, so touching it makes every fresh test build prompt
        // "Mnemosyne would like to access your Desktop". There is no default env
        // file anymore, but keep this guard for explicit paths in UI tests.
        let uitest = arguments.contains("--uitest")
        let dotenv = (uitest ? nil : envPath(environment: environment)).map { parseDotEnv(at: $0) } ?? [:]
        func value(_ keys: [String]) -> String? {
            for k in keys {
                if let v = environment[k], !v.isEmpty { return v }
                if let v = dotenv[k], !v.isEmpty { return v }
            }
            return nil
        }
        let explicitKey = value(["DEEPSEEK_API_KEY", "deepseek_api"])
        let settingsKey = settings.deepSeekKey
        let key = explicitKey ?? settingsKey
        let keySource: DeepSeekKeySource = explicitKey != nil
            ? .environment
            : (settingsKey.isEmpty ? .missing : .settings)
        return Config(
            deepSeekKey: key,
            deepSeekBaseURL: URL(string: value(["DEEPSEEK_BASE_URL"]) ?? "https://api.deepseek.com")!,
            deepSeekModel: value(["DEEPSEEK_MODEL"]) ?? "deepseek-v4-flash",
            ollamaBaseURL: URL(string: value(["OLLAMA_BASE_URL"]) ?? "http://127.0.0.1:11434")!,
            ollamaVisionModel: value(["OLLAMA_VISION_MODEL"]) ?? "gemma3:12b",
            deepSeekKeySource: keySource
        )
    }

    private static func parseDotEnv(at path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }
}
