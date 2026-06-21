import Foundation

/// Plain JSON file storage for API keys, in Application Support. Replaces the
/// Keychain, which prompted for permission on nearly every read/write. The file is
/// chmod 600 (user-only). Pure value type with an injectable path for tests.
struct SecretsFile: Sendable {
    let path: String
    init(path: String = SecretsFile.defaultPath) { self.path = path }

    static var defaultPath: String {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))?.path
            ?? NSHomeDirectory() + "/Library/Application Support"
        return base + "/Mnemosyne/secrets.json"
    }

    func read(_ key: String) -> String? {
        guard let v = load()[key], !v.isEmpty else { return nil }
        return v
    }

    /// True once `key` has been written at least once (so a one-time migration from
    /// the old Keychain isn't retried — and clearing a key doesn't fall back).
    func migrated(_ key: String) -> Bool { load()["__seen__:" + key] != nil }

    private func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return d
    }

    @discardableResult
    func write(_ key: String, _ value: String) -> Bool {
        var dict = load()
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { dict.removeValue(forKey: key) } else { dict[key] = v }
        dict["__seen__:" + key] = "1"   // remember we've managed this key

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let out = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try out.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { return false }
    }
}
