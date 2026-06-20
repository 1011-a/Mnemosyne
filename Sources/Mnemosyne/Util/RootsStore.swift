import Foundation

/// Remembers which folders the user has ingested so they can be re-scanned on
/// each launch (the ingestor's incremental skip makes re-scans cheap).
/// Persisted as plain paths in UserDefaults.
struct RootsStore {
    private let key = "mnemosyne.ingestedRoots"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var roots: [URL] {
        (defaults.array(forKey: key) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Add a root (de-duplicated, most-recent first). Returns the new list.
    @discardableResult
    func add(_ url: URL) -> [URL] {
        var paths = defaults.array(forKey: key) as? [String] ?? []
        let p = url.standardizedFileURL.path
        paths.removeAll { $0 == p }
        paths.insert(p, at: 0)
        defaults.set(paths, forKey: key)
        return paths.map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    func remove(_ url: URL) -> [URL] {
        var paths = defaults.array(forKey: key) as? [String] ?? []
        paths.removeAll { $0 == url.standardizedFileURL.path }
        defaults.set(paths, forKey: key)
        return paths.map { URL(fileURLWithPath: $0) }
    }
}
