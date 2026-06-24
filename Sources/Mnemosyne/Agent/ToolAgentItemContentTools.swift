import Foundation

/// Single-item content tool handlers — fetch raw text, summarize, outline, document-structure,
/// generate a table of contents, and find-in-item — extracted from `ToolAgent`'s main `handleTool`
/// switch to keep that file focused. Store-coupled (resolve one item and read its chunk text, several
/// returning cited evidence), so they live in an `extension ToolAgent` rather than migrating to
/// Fathom. `handleItemContentTool` returns nil when `name` isn't one of these, letting the caller
/// fall through.
extension ToolAgent {
    func handleItemContentTool(_ name: String, args: String, citationOffset: Int,
                               onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "get_item":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Opening \(it.title)…")
            let texts = (try? await store.chunkTexts(forItem: it.id)) ?? []
            let tags = (try? await store.tags(forItem: it.id)) ?? []
            let body = String(texts.joined(separator: "\n").prefix(2000))
            let meta = "kind=\(it.kind.rawValue) · \(it.byteSize) bytes · labels=[\(tags.joined(separator: ", "))] · path=\(it.path)"
            return ("\(it.title)\n\(meta)\n---\n\(body)", [])

        case "summarize_item":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading all of \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("'\(it.title)' has no readable text to summarize.", [])
            }
            return Self.itemSummaryFraming(title: it.title, path: it.path, itemID: it.id,
                                           fullText: full, citationOffset: citationOffset)

        case "outline_item":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Outlining \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let headings = Outline.extract(full)
            guard !headings.isEmpty else {
                return ("No clear headings/sections found in '\(it.title)' — try summarize_item for a prose summary instead.", [])
            }
            return ("Outline of '\(it.title)' (\(headings.count) heading(s)):\n\(Outline.render(headings))", [])

        case "document_outline":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading headings in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let outline = HeadingExtractor.outline(full) else {
                return ("No markdown headings (`#`) found in '\(it.title)' — try outline_item for an inferred structure.", [])
            }
            let n = HeadingExtractor.extract(full).count
            return ("Table of contents for '\(it.title)' (\(n) heading\(n == 1 ? "" : "s")):\n\(outline)", [])

        case "generate_toc":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Building TOC for \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let toc = TableOfContents.generate(full) else {
                return ("No markdown headings (`#`) found in '\(it.title)' to build a TOC.", [])
            }
            return ("Table of contents for '\(it.title)':\n\(toc)", [])

        case "find_in_item":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let query = arg("query"), !query.trimmingCharacters(in: .whitespaces).isEmpty else { return ("Missing 'query'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Searching \(it.title) for ‘\(query)’…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = LineGrep.summary(full, query: query) else {
                return ("No lines in '\(it.title)' contain '\(query)'.", [])
            }
            return ("In '\(it.title)':\n\(summary)", [])

        default:
            return nil
        }
    }
}
