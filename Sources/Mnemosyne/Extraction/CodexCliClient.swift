import Foundation

/// Visual/document understanding via the locally-installed `codex` CLI. This
/// uses the user's Codex/OpenAI login and runs Codex in read-only, ephemeral
/// exec mode so ingest can ask for descriptions without modifying files.
struct CodexCliClient: Sendable {

    /// Locate the `codex` binary. The `.app` is launched with a minimal PATH, so
    /// probe common install locations before falling back to a login-shell lookup.
    static let binaryPath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        let fm = FileManager.default
        for p in candidates where fm.isExecutableFile(atPath: p) { return p }
        return loginShellWhich("codex")
    }()

    static var isAvailable: Bool { binaryPath != nil }

    /// Describe a PNG (passed as raw bytes). Codex supports image attachments on
    /// the initial prompt, so we attach the temp PNG with `--image`.
    static func describe(
        pngData: Data,
        prompt: String = "describe it thoroughly: transcribe ALL visible text verbatim, then describe what it shows",
        timeout: TimeInterval = 180
    ) async -> String? {
        guard let bin = binaryPath else {
            IngestDebugLog.write("CODEX unavailable for image")
            return nil
        }
        let dir = FileManager.default.temporaryDirectory
        let image = dir.appendingPathComponent("mnemo-codex-vis-\(UUID().uuidString).png")
        let output = dir.appendingPathComponent("mnemo-codex-out-\(UUID().uuidString).txt")
        guard (try? pngData.write(to: image)) != nil else { return nil }
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: output)
        }

        let full = "Use the attached image and \(prompt). Output ONLY the result text, no preamble or commentary."
        return await run(
            bin: bin,
            args: execArgs(prompt: full, cwd: dir.path, imagePath: image.path, outputPath: output.path),
            outputPath: output.path,
            timeout: timeout,
            purpose: "image \(image.lastPathComponent)"
        )
    }

    /// Read a document file that Codex can inspect in read-only mode. Returns nil
    /// on failure/timeout so callers fall back to native extraction.
    static func readDocument(
        atPath path: String,
        prompt: String = "transcribe ALL text verbatim, preserving structure, and describe any tables, figures or charts",
        timeout: TimeInterval = 300
    ) async -> String? {
        guard let bin = binaryPath else {
            IngestDebugLog.write("CODEX unavailable for document \(URL(fileURLWithPath: path).lastPathComponent)")
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let cwd = url.deletingLastPathComponent().path
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mnemo-codex-out-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }

        let full = """
        Read this file in the current directory:
        \(url.lastPathComponent)

        \(prompt). Use read-only inspection commands if needed. Do not modify files. Output ONLY the result text, no preamble or commentary.
        """
        return await run(
            bin: bin,
            args: execArgs(prompt: full, cwd: cwd, imagePath: nil, outputPath: output.path),
            outputPath: output.path,
            timeout: timeout,
            purpose: "document \(url.lastPathComponent)"
        )
    }

    // MARK: - Process plumbing

    /// Developer-agent "create" via Codex: build a deliverable in `workdir` with a
    /// workspace-write sandbox so it can write files. Mirrors ClaudeCodeClient.createArtifact.
    static func createArtifact(task: String, context: String, workdir: String,
                               timeout: TimeInterval = 600) async -> String? {
        guard let bin = binaryPath else { return nil }
        let output = URL(fileURLWithPath: workdir).appendingPathComponent(".codex-out.txt")
        let prompt = """
        You are a BUILD AGENT. In the working directory, create this deliverable, writing ALL files here:
        \(task)

        Ground it ONLY in this CONTEXT from the user's knowledge base — do not invent facts:
        \(context)

        Make it polished and self-contained (inline CSS/JS for any HTML; no external assets).
        """
        let args = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-rules",
                    "--sandbox", "workspace-write", "--color", "never", "-C", workdir,
                    "-o", output.path, prompt]
        return await run(bin: bin, args: args, outputPath: output.path, timeout: timeout, purpose: "create")
    }

    private static func execArgs(prompt: String, cwd: String, imagePath: String?, outputPath: String) -> [String] {
        var args = [
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--color", "never",
            "-C", cwd,
            "-o", outputPath,
        ]
        // `--image <FILE>...` is variadic in Codex CLI, so the prompt must come
        // before it; otherwise the prompt is swallowed as another image path.
        args.append(prompt)
        if let imagePath { args += ["--image", imagePath] }
        return args
    }

    private static func run(bin: String, args: [String], outputPath: String, timeout: TimeInterval, purpose: String) async -> String? {
        IngestDebugLog.write("CODEX spawn purpose=\(purpose) bin=\(bin)")
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")

        // Robust timeout (SIGTERM → SIGKILL); merge stderr so failures are captured.
        let r = await ProcessRunner.run(bin: bin, args: args, timeout: timeout, env: env, mergeStderr: true)
        IngestDebugLog.write("CODEX exit status=\(r.status) timedOut=\(r.timedOut) purpose=\(purpose)")
        guard r.status == 0 else {
            let err = String(decoding: r.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty {
                IngestDebugLog.write("CODEX failure output=\(String(err.prefix(700)))")
            }
            return nil
        }

        let saved = (try? String(contentsOfFile: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: r.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (saved?.isEmpty == false) ? saved! : stdout
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
