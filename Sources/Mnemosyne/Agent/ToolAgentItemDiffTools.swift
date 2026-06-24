import Foundation

/// Item-comparison tool handlers (side-by-side compare / textual diff), extracted from `ToolAgent`'s
/// main `handleTool` switch to keep that file focused. Store-coupled — they resolve two items, pull
/// their chunk text, and return cited evidence for the model to summarize — so they live in an
/// `extension ToolAgent` rather than migrating to Fathom. `handleItemDiffTool` returns nil when
/// `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleItemDiffTool(_ name: String, args: String, citationOffset: Int,
                            onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "compare_items":
            guard let refA = arg("item_a"), let refB = arg("item_b") else { return ("Missing 'item_a' or 'item_b'.", []) }
            let ma = await resolveItems(refA), mb = await resolveItems(refB)
            guard ma.count == 1, let a = ma.first else { return (Self.ambiguity(ma, ref: refA), []) }
            guard mb.count == 1, let b = mb.first else { return (Self.ambiguity(mb, ref: refB), []) }
            onStatus("Comparing \(a.title) ↔ \(b.title)…")
            let ta = String(((try? await store.chunkTexts(forItem: a.id)) ?? []).joined(separator: "\n").prefix(1500))
            let tb = String(((try? await store.chunkTexts(forItem: b.id)) ?? []).joined(separator: "\n").prefix(1500))
            let n = citationOffset
            return ("[\(n + 1)] (\(a.title)) \(ta)\n[\(n + 2)] (\(b.title)) \(tb)\n",
                    [Citation(index: n + 1, title: a.title, path: a.path, snippet: String(ta.prefix(200)), itemID: a.id),
                     Citation(index: n + 2, title: b.title, path: b.path, snippet: String(tb.prefix(200)), itemID: b.id)])

        case "diff_items":
            guard let refA = arg("item_a"), let refB = arg("item_b") else { return ("Missing 'item_a' or 'item_b'.", []) }
            let ma = await resolveItems(refA), mb = await resolveItems(refB)
            guard ma.count == 1, let a = ma.first else { return (Self.ambiguity(ma, ref: refA), []) }
            guard mb.count == 1, let b = mb.first else { return (Self.ambiguity(mb, ref: refB), []) }
            onStatus("Diffing \(a.title) ↔ \(b.title)…")
            let ta = ((try? await store.chunkTexts(forItem: a.id)) ?? []).joined(separator: "\n")
            let tb = ((try? await store.chunkTexts(forItem: b.id)) ?? []).joined(separator: "\n")
            let changelog = TextDiff.changelog(ta, tb)
            let n = citationOffset
            let text = "Diff [\(n + 1)] \(a.title) (old) → [\(n + 2)] \(b.title) (new):\n\(changelog)\n\nSummarize what changed between these two files, citing [\(n + 1)] and [\(n + 2)]."
            return (text,
                    [Citation(index: n + 1, title: a.title, path: a.path, snippet: String(ta.prefix(200)), itemID: a.id),
                     Citation(index: n + 2, title: b.title, path: b.path, snippet: String(tb.prefix(200)), itemID: b.id)])

        default:
            return nil
        }
    }
}
