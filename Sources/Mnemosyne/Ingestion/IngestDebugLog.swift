import Foundation

/// Tiny append-only ingest trace for debugging which multimodal engine actually
/// ran. User-visible enough to inspect, quiet enough to leave enabled.
enum IngestDebugLog {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mnemosyne/ingest.log")
    }

    static func write(_ message: String) {
        let url = logURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
        NSLog("MnemosyneIngest %@", message)
    }
}
