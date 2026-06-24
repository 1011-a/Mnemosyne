import Foundation
import Fathom

/// Core tool handlers — primary knowledge search, label listing, past-conversation search, single-item
/// re-ingest, note saving, and current date/time — extracted from `ToolAgent`'s main `handleTool`
/// switch so that switch can be a pure dispatcher. Store-coupled (and `search_knowledge` needs the
/// turn's fallbackQuery + citationOffset), so they live in an `extension ToolAgent` rather than
/// migrating to Fathom. `handleCoreTool` returns nil when `name` isn't one of these, letting the
/// caller fall through.
extension ToolAgent {
    func handleCoreTool(_ name: String, args: String, fallbackQuery: String, citationOffset: Int,
                        onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "search_knowledge":
            let q = arg("query") ?? fallbackQuery
            onStatus("Searching: \(q)")
            let hits = (try? await store.search(vector: embedder.embed(q), queryText: q,
                                                k: topK, keywordWeight: keywordWeight)) ?? []
            return render(hits, startingAt: citationOffset)

        case "list_tags":
            onStatus("Reading labels…")
            let tags = (try? await store.allTags()) ?? []
            return tags.isEmpty ? ("No labels yet.", [])
                : (tags.map { "\($0.tag) (\($0.count))" }.joined(separator: ", "), [])

        case "search_conversations":
            guard let q = arg("query")?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty
            else { return ("Missing 'query'.", []) }
            onStatus("Searching past conversations for '\(q)'…")
            let threads = ((try? await store.searchThreads(query: q)) ?? []).prefix(10)
            guard !threads.isEmpty else { return ("No past conversations mention '\(q)'.", []) }
            let list = threads.map { t -> String in
                let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return "• \(title.isEmpty ? "(untitled)" : title) — \(Self.isoDay(t.updatedAt))\(t.pinned ? " 📌" : "")"
            }.joined(separator: "\n")
            return ("\(threads.count) past conversation(s) mentioning '\(q)':\n\(list)", [])

        case "reingest":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            guard FileManager.default.fileExists(atPath: it.path) else {
                return ("'\(it.title)' has no file on disk at \(it.path) to re-read.", [])
            }
            guard let onReingest else { return ("Re-ingest isn't available right now.", []) }
            onStatus("Re-reading \(it.title)…")
            await onReingest(it.path)
            return ("Re-ingested '\(it.title)' — re-extracted and re-embedded its current contents.", [])

        case "save_note":
            guard let title = arg("title")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let content = arg("content"), !title.isEmpty,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return ("Missing 'title' or 'content'.", []) }
            onStatus("Saving note '\(title)'…")
            let notesDir = NSHomeDirectory() + "/Documents/Mnemosyne Notes"
            try? FileManager.default.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
            let slug = String(title.lowercased().prefix(40)).map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let path = "\(notesDir)/\(Int(Date().timeIntervalSince1970))-\(String(slug)).md"
            let body = "# \(title)\n\n\(content)"
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
            let id = Hashing.sha256(path)
            let item = KnowledgeItem(id: id, path: path, title: "\(title).md", kind: .markdown,
                                     contentHash: Hashing.sha256(body), byteSize: Int64(body.utf8.count),
                                     createdAt: Date(), modifiedAt: Date(), summary: String(content.prefix(220)))
            let chunks = TextChunker.chunks(from: body).enumerated().compactMap { (i, t) -> Chunk? in
                let v = embedder.embed(t)
                return v.isEmpty ? nil : Chunk(id: "\(id)#\(i)", itemID: id, ordinal: i, text: t, embedding: v)
            }
            do { try await store.upsert(item: item, chunks: chunks) }
            catch { return ("Failed to save the note.", []) }
            return ("Saved note '\(title)' to your knowledge base — it's searchable now (\(path)).", [])

        case "current_datetime":
            // Delegate the formatting to Fathom's built-in datetime renderer.
            return ("Current local date and time: \(Fathom.CurrentDateTimeTool.render(Date(), style: .human)).", [])

        default:
            return nil
        }
    }
}
