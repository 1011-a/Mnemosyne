import Foundation
import AppKit

/// Artifact tool handlers (build / list / read / export / open), extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. Unlike the pure value-in/value-out tools, these
/// are store/network/UI-coupled — `create_artifact` grounds the build in the user's files and drives
/// the DeepSeek/Codex/Claude build engines — so they live in an `extension ToolAgent` (full access to
/// `store`, `embedder`, `deepSeek`, `buildEngine`) rather than migrating to Fathom. `handleArtifactTool`
/// returns nil when `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleArtifactTool(_ name: String, args: String,
                            onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "create_artifact":
            guard let task = arg("task") else { return ("Missing 'task'.", []) }
            // DeepSeek-native by default (no CLI). If a CLI engine is chosen, try it,
            // then the other CLI, then DeepSeek as a guaranteed fallback.
            let order = Self.buildOrder(preferred: buildEngine,
                                        claudeAvailable: ClaudeCodeClient.isAvailable,
                                        codexAvailable: CodexCliClient.isAvailable)
            // Ground the build in the user's own files.
            let hits = (try? await store.search(vector: embedder.embed(task), queryText: task,
                                                k: 6, keywordWeight: keywordWeight)) ?? []
            var context = hits.isEmpty ? "(no local sources matched — keep it general)"
                : hits.map { "- \($0.item.title): \(String($0.chunk.text.prefix(400)))" }.joined(separator: "\n")

            // Target: revise an existing artifact in place, or a fresh folder.
            let dir: String
            var revisedTitle: String?
            if let ref = arg("revise"), !ref.trimmingCharacters(in: .whitespaces).isEmpty {
                let arts = ArtifactStore.all()
                guard let a = ArtifactStore.find(ref, in: arts) else {
                    return ("No artifact named '\(ref)' to revise. You've built: \(arts.prefix(8).map(\.title).joined(separator: "; ")).", [])
                }
                dir = a.path; revisedTitle = a.title
                if let mp = a.mainPath, let existing = try? String(contentsOfFile: mp, encoding: .utf8) {
                    context += "\n\nThe directory already holds the CURRENT version. Existing file (\(a.mainFile ?? "")):\n" + String(existing.prefix(3000))
                }
            } else {
                dir = Self.artifactsDir(for: task)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            func filesNow() -> [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            }
            func mtimes() -> [String: Date] {
                var m: [String: Date] = [:]
                for f in filesNow() {
                    m[f] = (try? FileManager.default.attributesOfItem(atPath: dir + "/" + f))?[.modificationDate] as? Date
                }
                return m
            }
            let baseline = revisedTitle != nil ? mtimes() : [:]
            // Success: a fresh build produced files; a revision changed/added one.
            func produced() -> Bool {
                let now = mtimes()
                if revisedTitle == nil { return !now.isEmpty }
                for (f, m) in now where baseline[f] == nil || m > (baseline[f] ?? .distantPast) { return true }
                return false
            }
            let buildTask = revisedTitle != nil ? "REVISE the existing files here (read them first): \(task)" : task

            var used: String?
            for engine in order {
                onStatus("Building with \(engine.label): \(task)…")
                switch engine {
                case .deepseek:
                    // Native multi-file developer build (Claude Code-style). Falls back
                    // to a single self-contained HTML page if the manifest build yields nothing.
                    let built = await DeepSeekBuilder(deepSeek: deepSeek)
                        .build(task: buildTask, context: context, workdir: dir, onStatus: onStatus)
                    if built.isEmpty, let html = await deepSeekBuildHTML(task: buildTask, context: context) {
                        try? html.write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
                    }
                case .codex:
                    _ = await CodexCliClient.createArtifact(task: buildTask, context: context, workdir: dir)
                case .claude:
                    _ = await ClaudeCodeClient.createArtifact(task: buildTask, context: context, workdir: dir)
                }
                if produced() { used = engine.label; break }
                if order.count > 1 { onStatus("\(engine.label) produced nothing — trying the next build agent…") }
            }
            guard produced(), let used else {
                return ("Couldn't build it — every build agent failed (possibly all rate-limited). Try again later.", [])
            }
            // A revision invalidates the cached preview so the gallery re-renders it.
            if revisedTitle != nil { try? FileManager.default.removeItem(atPath: dir + "/.thumbnail.png") }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)]) }
            let files = filesNow()
            let verb = revisedTitle.map { "Revised '\($0)'" } ?? "Built \(files.count) file(s)"
            return ("\(verb) with \(used) — \(files.joined(separator: ", ")) — in \(dir). Revealed in Finder.", [])

        case "list_recent_artifacts":
            let limit = Int(arg("limit") ?? "") ?? 8
            let arts = ArtifactStore.all().prefix(max(1, min(limit, 30)))
            return arts.isEmpty ? ("You haven't built any artifacts yet.", [])
                : ("Artifacts you've built: " +
                   arts.map { "\($0.title) (\($0.files.count) file\($0.files.count == 1 ? "" : "s"))" }.joined(separator: "; "), [])

        case "read_artifact":
            guard let ref = arg("name") else { return ("Missing 'name'.", []) }
            let arts = ArtifactStore.all()
            guard let a = ArtifactStore.find(ref, in: arts), let mp = a.mainPath else {
                return arts.isEmpty ? ("No artifacts built yet.", [])
                    : ("No artifact matches '\(ref)'. You've built: \(arts.prefix(8).map(\.title).joined(separator: "; ")).", [])
            }
            onStatus("Reading artifact \(a.title)…")
            let content = String(((try? String(contentsOfFile: mp, encoding: .utf8)) ?? "").prefix(4000))
            return ("Artifact '\(a.title)' — \(a.mainFile ?? "") at \(a.path):\n\(content)", [])

        case "export_artifact":
            guard let ref = arg("name") else { return ("Missing 'name'.", []) }
            let arts = ArtifactStore.all()
            guard let a = ArtifactStore.find(ref, in: arts) else {
                return arts.isEmpty ? ("No artifacts built yet.", [])
                    : ("No artifact matches '\(ref)'. You've built: \(arts.prefix(8).map(\.title).joined(separator: "; ")).", [])
            }
            onStatus("Exporting \(a.title)…")
            guard let zip = ArtifactStore.export(a) else {
                return ("Couldn't export '\(a.title)' — the zip step failed.", [])
            }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: zip)]) }
            return ("Exported '\(a.title)' to \(zip). Revealed it in Finder.", [])

        case "open_artifact":
            guard let ref = arg("name") else { return ("Missing 'name'.", []) }
            let arts = ArtifactStore.all()
            guard let a = ArtifactStore.find(ref, in: arts), let mp = a.mainPath else {
                return arts.isEmpty ? ("No artifacts built yet.", [])
                    : ("No artifact matches '\(ref)'. You've built: \(arts.prefix(8).map(\.title).joined(separator: "; ")).", [])
            }
            onStatus("Opening \(a.title)…")
            await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: mp)) }
            return ("Opened '\(a.title)' (\(a.mainFile ?? "")).", [])

        default:
            return nil
        }
    }
}
