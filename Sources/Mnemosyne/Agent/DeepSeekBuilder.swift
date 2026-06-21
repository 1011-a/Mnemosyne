import Foundation

/// A native, DeepSeek-driven developer agent for `create_artifact` — no external CLI.
/// Instead of one one-shot HTML page, it asks DeepSeek for a MULTI-FILE manifest
/// (e.g. index.html + style.css + app.js, or a small code project), writes each file
/// safely into the workdir, then runs a bounded self-review pass that can replace or
/// add files — bringing the native builder closer to a Claude Code-style agent.
struct DeepSeekBuilder: Sendable {
    let deepSeek: DeepSeekClient

    struct BuiltFile: Equatable, Sendable { let path: String; let content: String }

    /// Generate → write → (optionally) refine. Returns the relative paths written.
    func build(task: String, context: String, workdir: String, refinePasses: Int = 1,
               onStatus: @Sendable @escaping (String) -> Void = { _ in }) async -> [String] {
        onStatus("DeepSeek is planning the build…")
        guard var files = await generate(task: task, context: context, prior: nil), !files.isEmpty else {
            return []
        }
        var written = writeFiles(files, to: workdir)

        // Self-review: let DeepSeek inspect its own manifest and improve it. Bounded.
        var pass = 0
        while pass < refinePasses, !written.isEmpty {
            pass += 1
            onStatus("DeepSeek is reviewing & polishing (pass \(pass))…")
            guard let improved = await generate(task: task, context: context, prior: files),
                  !improved.isEmpty else { break }
            // Only re-write if the review actually changed something.
            if improved == files { break }
            files = improved
            written = writeFiles(files, to: workdir)
        }
        return written
    }

    /// Write a manifest into `workdir`, skipping unsafe paths. Returns paths written.
    private func writeFiles(_ files: [BuiltFile], to workdir: String) -> [String] {
        var written: [String] = []
        for f in files {
            guard let safe = Self.safeRelativePath(f.path) else { continue }
            let full = workdir + "/" + safe
            let parent = (full as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            if (try? f.content.write(toFile: full, atomically: true, encoding: .utf8)) != nil {
                written.append(safe)
            }
        }
        return written
    }

    /// One structured (JSON-mode) generation. `prior` non-nil ⇒ a refine pass.
    private func generate(task: String, context: String, prior: [BuiltFile]?) async -> [BuiltFile]? {
        let body: [String: Any] = [
            "model": deepSeek.config.deepSeekModel,
            "messages": [["role": "system", "content": Self.systemPrompt(refining: prior != nil)],
                         ["role": "user", "content": Self.userPrompt(task: task, context: context, prior: prior)]],
            "temperature": 0.4,
            "tool_choice": "none",
            "response_format": ["type": "json_object"],
        ]
        guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
              let resp = try? JSONDecoder().decode(ToolAgent.ChatResponse.self, from: data) else { return nil }
        return Self.parseFiles(resp.choices.first?.message.content ?? "")
    }

    // MARK: prompts

    static func systemPrompt(refining: Bool) -> String {
        let base = """
        You are a senior developer build agent. Produce a COMPLETE, polished, self-contained \
        deliverable as a SET OF FILES. Choose the right shape for the task: a data dashboard or \
        report is usually index.html plus style.css and app.js; a tool may be a small code project \
        with a README. Use only inline/local assets (no network CDNs). Make it production-quality: \
        real layout, real styling, working interactivity, and accurate content grounded ONLY in the \
        provided context — never invent facts.
        Respond with ONLY a JSON object of this exact shape:
        {"files":[{"path":"index.html","content":"<full file text>"},{"path":"style.css","content":"..."}]}
        Paths are RELATIVE (no leading slash, no ".."). Include every file needed to run it.
        """
        return refining
            ? base + "\nYou are REVISING your previous attempt: fix bugs, improve the design and completeness, and return the FULL updated file set (not a diff)."
            : base
    }

    static func userPrompt(task: String, context: String, prior: [BuiltFile]?) -> String {
        var p = "Deliverable: \(task)\n\nGround it ONLY in this context:\n\(context)"
        if let prior, !prior.isEmpty {
            let dump = prior.map { "=== \($0.path) ===\n\(String($0.content.prefix(4000)))" }.joined(separator: "\n\n")
            p += "\n\nYour previous attempt (improve it):\n\(dump)"
        }
        return p
    }

    // MARK: pure parsing / safety

    /// Parse a `{"files":[{path,content}]}` manifest. Tolerant: ignores entries
    /// missing path/content; returns [] on malformed JSON.
    static func parseFiles(_ json: String) -> [BuiltFile] {
        let trimmed = ToolAgent.extractHTML(json)   // strips any stray ``` fences
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["files"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let path = (d["path"] as? String)?.trimmingCharacters(in: .whitespaces), !path.isEmpty,
                  let content = d["content"] as? String, !content.isEmpty else { return nil }
            return BuiltFile(path: path, content: content)
        }
    }

    /// A safe relative path inside the workdir, or nil if it escapes (absolute, "..").
    static func safeRelativePath(_ path: String) -> String? {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        guard !p.isEmpty, !p.hasPrefix("/"), !p.hasPrefix("~"),
              !p.split(separator: "/").contains("..") else { return nil }
        return p
    }
}
