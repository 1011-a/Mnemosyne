import Foundation

/// Visual understanding via the locally-installed `claude` CLI — the user's own
/// Claude Code login, so no API key is needed. Claude reads an image from a file
/// path (via its Read tool) and returns a description on stdout.
///
/// Trade-offs (measured): excellent description quality, but per-call agent
/// startup is heavy (~5–7s) and concurrent calls contend/rate-limit, so it runs
/// serially and is not faster than downscaled Gemma. Opt-in via `VisionEngine`.
struct ClaudeCodeClient: Sendable {

    /// Locate the `claude` binary. The `.app` is launched with a minimal PATH, so
    /// probe the usual install locations before falling back to a login-shell lookup.
    static let binaryPath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        let fm = FileManager.default
        for p in candidates where fm.isExecutableFile(atPath: p) { return p }
        return loginShellWhich("claude")
    }()

    static var isAvailable: Bool { binaryPath != nil }

    /// Ingest uses Sonnet, not Opus: vision/transcription doesn't need Opus-level
    /// reasoning, and Sonnet is much cheaper (and a touch faster) — important when
    /// a library is hundreds of files.
    static let ingestModel = "sonnet"

    /// Describe a PNG (passed as raw bytes). Writes a temp file because `claude`
    /// reads images by path. Returns trimmed stdout, or nil on failure/timeout.
    static func describe(
        pngData: Data,
        prompt: String = "describe it thoroughly: transcribe ALL visible text verbatim, then describe what it shows",
        timeout: TimeInterval = 120
    ) async -> String? {
        guard let bin = binaryPath else {
            IngestDebugLog.write("CLAUDE unavailable for image")
            return nil
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemo-vis-\(UUID().uuidString).png")
        guard (try? pngData.write(to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let full = "Read the image at \(tmp.path) and \(prompt). Output ONLY the result text, no preamble or commentary."
        return await run(bin: bin, args: ["-p", full, "--allowedTools", "Read", "--model", ingestModel],
                         timeout: timeout, purpose: "image \(tmp.lastPathComponent)")
    }

    /// Read a document FILE that Claude can open by path (PDF, plain text, notebooks).
    /// Returns nil on failure/timeout so callers fall back to native extraction.
    /// Larger timeout than images since a long PDF may take a while.
    static func readDocument(
        atPath path: String,
        prompt: String = "transcribe ALL text verbatim, preserving structure, and describe any tables, figures or charts",
        timeout: TimeInterval = 240
    ) async -> String? {
        guard let bin = binaryPath else {
            IngestDebugLog.write("CLAUDE unavailable for document \(URL(fileURLWithPath: path).lastPathComponent)")
            return nil
        }
        let full = "Read the file at \(path) and \(prompt). Output ONLY the result text, no preamble or commentary."
        return await run(bin: bin, args: ["-p", full, "--allowedTools", "Read", "--model", ingestModel],
                         timeout: timeout, purpose: "document \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    /// Developer-agent "create" capability: run the claude CLI as a BUILD AGENT in
    /// `workdir` to produce a deliverable (report, visualization, mini-app, code),
    /// grounded in `context` from the user's files. Only Read/Edit/Write are allowed
    /// (no shell) and writes land in `workdir`. Returns the agent's stdout, or nil.
    static func createArtifact(task: String, context: String, workdir: String,
                               timeout: TimeInterval = 600) async -> String? {
        guard let bin = binaryPath else { return nil }
        let prompt = """
        You are a BUILD AGENT working in the current directory. Produce this deliverable, writing ALL \
        files into the current directory:

        \(task)

        Ground it ONLY in this CONTEXT from the user's knowledge base — do not invent facts; cite source \
        filenames where relevant:
        \(context)

        Make it polished and self-contained (inline CSS/JS for any HTML; no external assets). When finished, \
        print on the LAST line exactly: ARTIFACT_FILES: <comma-separated names of the files you created>.
        """
        return await run(bin: bin,
                         args: ["-p", prompt, "--allowedTools", "Read Edit Write",
                                "--permission-mode", "acceptEdits", "--model", ingestModel],
                         timeout: timeout, purpose: "create", cwd: workdir)
    }

    // MARK: - Process plumbing

    private static func run(bin: String, args: [String], timeout: TimeInterval, purpose: String,
                            cwd: String? = nil) async -> String? {
        IngestDebugLog.write("CLAUDE spawn purpose=\(purpose) bin=\(bin)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice          // avoid claude's 3s stdin wait
        // Ensure claude (a Node app) can find node/itself even under the .app's
        // stripped PATH; keep the user's HOME so it finds ~/.claude credentials.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        proc.environment = env

        do { try proc.run() } catch { return nil }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if proc.isRunning { proc.terminate() }
        }
        let data: Data = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: d)
            }
        }
        watchdog.cancel()
        IngestDebugLog.write("CLAUDE exit status=\(proc.terminationStatus) purpose=\(purpose)")
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Last-resort lookup through the user's login shell (picks up custom PATHs).
    private static func loginShellWhich(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
