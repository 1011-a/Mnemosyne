import Foundation

/// One artifact the agent built — a folder under ~/Documents/Mnemosyne Artifacts.
struct Artifact: Identifiable, Sendable, Equatable {
    let id: String          // absolute folder path (stable id)
    let title: String       // human title derived from the folder slug
    let date: Date          // when it was created
    let files: [String]     // file names inside
    let mainFile: String?   // the file to open (index.html / first .html / first)

    var path: String { id }
    var mainPath: String? { mainFile.map { id + "/" + $0 } }
}

/// Lists and manages the deliverables produced by `create_artifact`.
enum ArtifactStore {
    static var directory: String { NSHomeDirectory() + "/Documents/Mnemosyne Artifacts" }

    /// All artifacts, newest first. `dir` is injectable for tests.
    static func all(in dir: String = ArtifactStore.directory) -> [Artifact] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Artifact] = []
        for entry in entries where !entry.hasPrefix(".") {
            let folder = dir + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { continue }
            let files = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            guard !files.isEmpty else { continue }
            let date = ((try? fm.attributesOfItem(atPath: folder))?[.creationDate] as? Date) ?? .distantPast
            let main = files.first { $0.lowercased() == "index.html" }
                ?? files.first { $0.lowercased().hasSuffix(".html") } ?? files.first
            out.append(Artifact(id: folder, title: title(from: entry), date: date, files: files, mainFile: main))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Resolve an artifact by title: exact match (case-insensitive), then substring.
    static func find(_ ref: String, in artifacts: [Artifact]) -> Artifact? {
        let k = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return nil }
        return artifacts.first { $0.title.lowercased() == k } ?? artifacts.first { $0.title.lowercased().contains(k) }
    }

    /// "1718900000-my-cool-dashboard" → "My Cool Dashboard".
    static func title(from folderName: String) -> String {
        var parts = folderName.split(separator: "-").map(String.init)
        if let first = parts.first, Int(first) != nil { parts.removeFirst() }   // drop the timestamp
        let words = parts.filter { !$0.isEmpty }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? "Artifact" : words.joined(separator: " ")
    }

    @discardableResult
    static func delete(_ artifact: Artifact) -> Bool {
        (try? FileManager.default.removeItem(atPath: artifact.path)) != nil
    }

    /// Zip an artifact's folder into `dir` (default ~/Desktop) for sharing. Returns
    /// the .zip path, or nil on failure. Uses `ditto` (always present on macOS).
    static func export(_ artifact: Artifact,
                       toDirectory dir: String = NSHomeDirectory() + "/Desktop") -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let zipPath = dir + "/" + exportFileName(artifact.title) + ".zip"
        try? fm.removeItem(atPath: zipPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", artifact.path, zipPath]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return (p.terminationStatus == 0 && fm.fileExists(atPath: zipPath)) ? zipPath : nil
    }

    /// A filesystem-safe base name from an artifact title.
    static func exportFileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Artifact" : cleaned
    }
}
