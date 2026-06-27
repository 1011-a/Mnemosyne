import Foundation

/// Tiny append-only trace of each Ask-tab agent turn — the tool trajectory, finish reason, and search
/// count — for debugging "why did it answer that?" (a wrong answer has no stack trace, only a
/// trajectory). Mirrors `IngestDebugLog`: user-inspectable, quiet enough to leave enabled.
enum AgentDebugLog {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mnemosyne/agent.log")
    }

    static func write(_ message: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            do { try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() }
            catch { try? handle.close() }
        }
        NSLog("MnemosyneAgent %@", message)
    }
}
