import Foundation
import AppKit
import Fathom

/// Artifact tool handlers (build / list / read / export / open), extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. `create_artifact` is the agent's general "produce a
/// deliverable by writing & running code" capability: it grounds the build in the user's files and
/// runs a **Fathom-native coding agent** (Fathom.Orchestrator + a sandboxed FileSandbox.codingTools
/// loop driven by the app's DeepSeek client) in a fresh working directory — no third-party agent CLI.
/// They live in an `extension ToolAgent` (full access to `store`, `embedder`, `deepSeek`).
/// `handleArtifactTool` returns nil when `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    /// System prompt for the Fathom-native build agent (file + sandboxed-shell tools).
    static let artifactBuilderSystemPrompt = """
    You are a BUILD AGENT working in a sandboxed working directory. You have tools to read, write, and \
    edit files, to list/glob/grep, and to run shell commands. The shell has NO network access and can \
    only write inside this working directory, so do not try to install packages or fetch anything.

    Produce the requested DELIVERABLE as real files in the working directory:
    - Ground all content ONLY in the provided CONTEXT from the user's knowledge base — do not invent facts.
    - Make it polished and self-contained. For HTML, inline all CSS/JS (no external assets — there is no network).
    - If a PDF is requested: write the document as a self-contained HTML file, then render it to PDF with \
      `cupsfilter <file>.html > <file>.pdf` (works offline on macOS). Confirm the .pdf file exists afterward.
    - Keep working until the deliverable files exist on disk; do not ask the user questions. \
    When finished, briefly state what you built and name the main file.
    """

    /// External end-state check for create_artifact (research: verify on the environment, not by
    /// self-grading). Returns a feedback string describing what's still missing — no new files, or a
    /// requested PDF absent — to feed into ONE grounded retry, or nil when the deliverable looks
    /// complete. Pure → unit-testable.
    static func artifactShortfall(files: [String], wantsPDF: Bool, baseline: Set<String>, revising: Bool) -> String? {
        let producedSomething = revising ? (Set(files) != baseline) : !files.isEmpty
        if !producedSomething {
            return "The previous attempt wrote no new files to the working directory. Actually write the deliverable file(s) here now."
        }
        if wantsPDF, !files.contains(where: { $0.lowercased().hasSuffix(".pdf") }) {
            return "A PDF was requested but none exists in the directory. Render the document to a .pdf (write the HTML, then run: cupsfilter <file>.html > <file>.pdf) and confirm the .pdf file exists."
        }
        return nil
    }

    func handleArtifactTool(_ name: String, args: String,
                            onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "create_artifact":
            guard let task = arg("task") else { return ("Missing 'task'.", []) }
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
            let baseline = Set(filesNow())

            // Native coding agent: a sandboxed Fathom Orchestrator loop (no network; writes confined
            // to `dir`) driven by the app's DeepSeek client. It writes & runs code to build the deliverable.
            let buildTask = revisedTitle != nil ? "REVISE the existing files in this directory (read them first): \(task)" : task
            let wantsPDF = task.lowercased().contains("pdf")
            let sandbox = Fathom.FileSandbox(root: URL(fileURLWithPath: dir))
            let orchestrator = Fathom.Orchestrator(
                client: Self.retrying(AgentLLMClient(deepSeek: deepSeek, temperature: 0.4)),
                maxRounds: 16, onStatus: { onStatus($0) }, planning: true)
            func runBuild(_ note: String) async {
                let query = """
                Deliverable: \(buildTask)\(note.isEmpty ? "" : "\n\nIMPORTANT — fix this from the last attempt: \(note)")

                CONTEXT from the user's knowledge base (ground in this; do not invent):
                \(context)
                """
                _ = try? await orchestrator.run(systemPrompt: Self.artifactBuilderSystemPrompt,
                                                query: query,
                                                tools: sandbox.codingTools(commandTimeout: 180, sandboxed: true))
            }

            // End-state verification grounded in the filesystem (not self-grading): build, then if the
            // deliverable is short (no new files, or a requested PDF missing) retry ONCE with the
            // specific gap fed back — rounds 1–2 capture most recoverable gain (harness research).
            onStatus("Building: \(task)…")
            await runBuild("")
            if let gap = Self.artifactShortfall(files: filesNow(), wantsPDF: wantsPDF, baseline: baseline, revising: revisedTitle != nil) {
                onStatus("Refining the build…")
                await runBuild(gap)
            }

            let files = filesNow()
            let produced = revisedTitle == nil ? !files.isEmpty : Set(files) != baseline || !files.isEmpty
            guard produced else {
                return ("Couldn't build it — the build agent produced no files. Try rephrasing the request.", [])
            }
            // A revision invalidates the cached preview so the gallery re-renders it.
            if revisedTitle != nil { try? FileManager.default.removeItem(atPath: dir + "/.thumbnail.png") }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)]) }
            let pdfNote = (wantsPDF && !files.contains { $0.lowercased().hasSuffix(".pdf") })
                ? " (couldn't render a PDF — the document files are in the folder)" : ""
            let verb = revisedTitle.map { "Revised '\($0)'" } ?? "Built \(files.count) file(s)"
            return ("\(verb) — \(files.joined(separator: ", ")) — in \(dir). Revealed in Finder.\(pdfNote)", [])

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
