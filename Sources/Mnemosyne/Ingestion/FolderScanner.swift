import Foundation

/// Deep-enumerates a directory for ingestible files, skipping the noise that
/// pollutes a personal corpus (hidden files, caches, build output, bundles).
enum FolderScanner {
    private static let skipDirNames: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "Pods", ".venv", "venv",
        "__pycache__", ".cache", "Caches", ".Trash", "Library/Caches", ".next", "dist", "build"
    ]
    /// Treat these bundle extensions as opaque single items, not folders to recurse into.
    private static let opaqueBundleExts: Set<String> = ["app", "framework", "xcodeproj", "photoslibrary", "bundle"]

    static func scan(_ root: URL, maxFileBytes: Int64 = 25_000_000) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isHiddenKey]
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent

            if vals?.isDirectory == true {
                // iWork bundles are packages — treat the bundle itself as one item.
                if TypeDetector.isIWork(url) { out.append(url); en.skipDescendants(); continue }
                if name.hasPrefix(".") || skipDirNames.contains(name) {
                    en.skipDescendants()
                }
                continue
            }
            if name.hasPrefix(".") || vals?.isHidden == true { continue }
            if opaqueBundleExts.contains(url.pathExtension.lowercased()) { continue }
            guard let kind = TypeDetector.kind(for: url) else { continue }
            // Audio (transcribed) can be much larger than text/docs.
            let cap = kind == .audioTranscript ? 400_000_000 : maxFileBytes
            if let size = vals?.fileSize, Int64(size) > cap { continue }
            out.append(url)
        }
        return out
    }
}
