import Foundation
import AppKit

/// Item-management tool handlers — recency/size/age listings, date filters, relatedness and
/// connection discovery, Finder reveal/open, and item deletion — extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. Store/UI-coupled (query the store, surface related
/// items as cited evidence, drive Finder, mutate the index), so they live in an `extension ToolAgent`
/// rather than migrating to Fathom. `handleItemTool` returns nil when `name` isn't one of these,
/// letting the caller fall through.
extension ToolAgent {
    func handleItemTool(_ name: String, args: String, citationOffset: Int,
                        onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "recent_items":
            onStatus("Listing recent files…")
            let limit = Int(arg("limit") ?? "") ?? 10
            let items = ((try? await store.allItems()) ?? [])
                .sorted { max($0.modifiedAt, $0.createdAt) > max($1.modifiedAt, $1.createdAt) }
                .prefix(max(1, min(limit, 50)))
            return items.isEmpty ? ("The knowledge base is empty.", [])
                : ("Most recent: " + items.map { "\($0.title) (\($0.kind.rawValue))" }.joined(separator: "; "), [])

        case "largest_items":
            onStatus("Finding the biggest files…")
            let limit = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 10, 1), 50)
            let biggest = ((try? await store.allItems()) ?? [])
                .sorted { $0.byteSize > $1.byteSize }.prefix(limit)
            return biggest.isEmpty ? ("The knowledge base is empty.", [])
                : ("Largest files: " + biggest.map { "\($0.title) (\(Self.humanBytes($0.byteSize)))" }.joined(separator: "; "), [])

        case "oldest_items":
            onStatus("Finding the oldest files…")
            let n = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 10, 1), 50)
            let oldest = ((try? await store.allItems()) ?? [])
                .sorted { Swift.max($0.modifiedAt, $0.createdAt) < Swift.max($1.modifiedAt, $1.createdAt) }.prefix(n)
            return oldest.isEmpty ? ("The knowledge base is empty.", [])
                : ("Oldest files: " + oldest.map { "\($0.title) (\(Self.isoDay(Swift.max($0.modifiedAt, $0.createdAt))))" }.joined(separator: "; "), [])

        case "recent_changes":
            onStatus("Finding recent changes…")
            let threshold = Self.changeThreshold(days: Int(arg("days") ?? ""), since: arg("since"), now: Date())
            let changed = Self.changedSince((try? await store.allItems()) ?? [], threshold).prefix(40)
            let since = Self.isoDay(threshold)
            guard !changed.isEmpty else { return ("No files changed since \(since).", []) }
            let list = changed.map { "\($0.title) (\($0.kind.rawValue), \(Self.isoDay(max($0.modifiedAt, $0.createdAt))))" }
                .joined(separator: "; ")
            return ("\(changed.count) file(s) changed since \(since): \(list)", [])

        case "find_by_date":
            onStatus("Searching by date…")
            let start = Self.parseISODate(arg("start"))
            let end = Self.parseISODate(arg("end"))
            guard start != nil || end != nil else {
                return ("Give at least one of 'start' or 'end' (ISO date YYYY-MM-DD).", [])
            }
            let useModified = (arg("field")?.lowercased() ?? "modified") != "created"
            let n = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 25, 1), 100)
            let hits = Self.inDateRange((try? await store.allItems()) ?? [],
                                        start: start, end: end, useModified: useModified)
            let field = useModified ? "modified" : "created"
            let range: String = {
                switch (start, end) {
                case let (s?, e?): return "\(Self.isoDay(s)) … \(Self.isoDay(e))"
                case let (s?, nil): return "since \(Self.isoDay(s))"
                case let (nil, e?): return "up to \(Self.isoDay(e))"
                default:            return "any time"
                }
            }()
            guard !hits.isEmpty else { return ("No files \(field) in \(range).", []) }
            let shown = hits.prefix(n)
            let list = shown.map { "\($0.title) (\($0.kind.rawValue), \(Self.isoDay(useModified ? $0.modifiedAt : $0.createdAt)))" }
                .joined(separator: "; ")
            let more = hits.count > shown.count ? " (+\(hits.count - shown.count) more)" : ""
            return ("\(hits.count) file(s) \(field) in \(range): \(list)\(more)", [])

        case "related_items":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding files related to \(it.title)…")
            let related = (try? await store.relatedItems(to: it.id, k: 6)) ?? []
            return render(related, startingAt: citationOffset)

        case "suggest_connections":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Looking for unlinked connections to \(it.title)…")
            let related = (try? await store.relatedItems(to: it.id, k: 8)) ?? []
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let sourceTags = Set(byItem[it.id] ?? [])
            let candidates = related.map { (id: $0.item.id, title: $0.item.title,
                                            tags: Set(byItem[$0.item.id] ?? [])) }
            let connections = Self.suggestedConnections(sourceTags: sourceTags, candidates: candidates)
            guard !connections.isEmpty else {
                return ("No unlinked connections for '\(it.title)' — its related files already share a label (or there are no related files).", [])
            }
            let names = connections.prefix(6).map { "'\($0.title)'" }.joined(separator: ", ")
            let tagHint = sourceTags.isEmpty
                ? "'\(it.title)' has no labels yet — consider adding one and applying it across these."
                : "None share a label with '\(it.title)' (its labels: \(sourceTags.sorted().joined(separator: ", "))). Offer to co-tag them."
            return ("\(connections.count) possible connection(s) to '\(it.title)': \(names). \(tagHint)", [])

        case "suggest_tags_from_neighbors":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Learning labels from files similar to \(it.title)…")
            let neighbors = (try? await store.relatedItems(to: it.id, k: 8)) ?? []
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let existing = Set(byItem[it.id] ?? [])
            let neighborTags = neighbors.map { byItem[$0.item.id] ?? [] }
            let proposed = Self.tagsFromNeighbors(existing: existing, neighborTags: neighborTags)
            guard !proposed.isEmpty else {
                return ("No label suggestions for '\(it.title)' from similar files (its neighbors are untagged, or it already shares their labels).", [])
            }
            return ("Labels used by files similar to '\(it.title)': \(proposed.joined(separator: ", ")). Want me to add any with add_tag?", [])

        case "reveal_in_finder":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            guard FileManager.default.fileExists(atPath: it.path) else {
                return ("'\(it.title)' has no file on disk at \(it.path) (it may be a bookmark or have moved).", [])
            }
            onStatus("Revealing \(it.title) in Finder…")
            let url = URL(fileURLWithPath: it.path)
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return ("Revealed '\(it.title)' in Finder.", [])

        case "open_file":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            guard FileManager.default.fileExists(atPath: it.path) else {
                return ("'\(it.title)' has no file on disk at \(it.path).", [])
            }
            onStatus("Opening \(it.title)…")
            let url = URL(fileURLWithPath: it.path)
            await MainActor.run { NSWorkspace.shared.open(url) }
            return ("Opened '\(it.title)' in its default app.", [])

        case "delete_item":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            // Safety: NEVER fuzzy-delete — require an exact (case-insensitive) title.
            let items = (try? await store.allItems()) ?? []
            let r = ref.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let exact = items.filter { $0.title.lowercased() == r }
            guard exact.count == 1, let it = exact.first else {
                let near = items.filter { $0.title.lowercased().contains(r) }.prefix(8).map(\.title)
                return ("To delete, give the EXACT file title. " +
                        (near.isEmpty ? "No close matches to '\(ref)'." : "Close matches: \(near.joined(separator: "; "))."), [])
            }
            // Safe deletion: never delete without explicit confirmation. The first
            // call only previews; the agent must relay this and the user must confirm.
            guard Self.boolArg(args, "confirm") else {
                let chunks = (try? await store.chunkTexts(forItem: it.id))?.count ?? 0
                return ("CONFIRM NEEDED — this will remove '\(it.title)' (\(it.kind.rawValue), \(chunks) chunks) " +
                        "from the knowledge base (the file on disk is untouched, this is not reversible in-app). " +
                        "Ask the user to confirm, then call delete_item again with confirm=true.", [])
            }
            onStatus("Removing \(it.title) from the knowledge base…")
            do { try await store.deleteItems(ids: [it.id]) }
            catch { return ("Failed to remove '\(it.title)'.", []) }
            return ("Removed '\(it.title)' from the knowledge base. The file on disk is untouched.", [])

        default:
            return nil
        }
    }
}
