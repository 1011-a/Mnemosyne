import Foundation

/// Tag-management tool handlers — label suggestion, bulk auto-labelling, add/remove/rename/delete,
/// merge, untagged listing, and tagging search results — extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. Store-coupled (read and mutate the tag tables), so
/// they live in an `extension ToolAgent` rather than migrating to Fathom. `handleTagTool` returns nil
/// when `name` isn't one of these, letting the caller fall through. (Tag *queries* that read like
/// library analytics — tag_stats, find_by_tag, summarize_tag — live with the library tools.)
extension ToolAgent {
    func handleTagTool(_ name: String, args: String,
                       onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "suggest_labels":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Suggesting labels for \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let keywords = KeywordExtractor.topTerms(full, limit: 12).map(\.term)
            let libTags = ((try? await store.allTags()) ?? []).map(\.tag)
            let itemTags = (try? await store.tags(forItem: it.id)) ?? []
            let proposed = Self.proposeLabels(keywords: keywords, existingTags: libTags, itemTags: itemTags)
            guard !proposed.isEmpty else {
                return ("No new label suggestions for '\(it.title)' — it may already be well-labelled.", [])
            }
            guard Self.boolArg(args, "apply") else {
                return ("Suggested labels for '\(it.title)': \(proposed.joined(separator: ", ")). Call again with apply=true to add them.", [])
            }
            var tags = itemTags
            for p in proposed where !tags.contains(where: { $0.lowercased() == p.lowercased() }) { tags.append(p) }
            _ = try? await store.setTags(tags, forItem: it.id)
            return ("Added labels to '\(it.title)': \(proposed.joined(separator: ", ")).", [])

        case "auto_label_untagged":
            onStatus("Finding untagged files…")
            let limit = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 10, 1), 30)
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let libTags = ((try? await store.allTags()) ?? []).map(\.tag)
            let untagged = ((try? await store.allItems()) ?? [])
                .filter { (byItem[$0.id] ?? []).isEmpty }.prefix(limit)
            guard !untagged.isEmpty else { return ("No untagged files — everything's already labelled.", []) }
            // Build a label proposal per file (≤3 each), reusing library vocabulary.
            var plans: [(item: KnowledgeItem, labels: [String])] = []
            for it in untagged {
                let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
                let kws = KeywordExtractor.topTerms(full, limit: 10).map(\.term)
                let labels = Self.proposeLabels(keywords: kws, existingTags: libTags, itemTags: [], limit: 3)
                if !labels.isEmpty { plans.append((it, labels)) }
            }
            guard !plans.isEmpty else { return ("Couldn't derive labels for the untagged files (too little text).", []) }
            guard Self.boolArg(args, "apply") else {
                let preview = plans.map { "\($0.item.title) → \($0.labels.joined(separator: ", "))" }.joined(separator: "; ")
                return ("Proposed labels for \(plans.count) untagged file(s): \(preview). Call again with apply=true to apply them.", [])
            }
            var done = 0
            for p in plans where (try? await store.setTags(p.labels, forItem: p.item.id)) != nil { done += 1 }
            return ("Auto-labelled \(done) of \(plans.count) untagged file(s).", [])

        case "add_tag", "remove_tag":
            guard let ref = arg("item"),
                  let tag = arg("tag")?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty
            else { return ("Missing 'item' or 'tag'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            var tags = (try? await store.tags(forItem: it.id)) ?? []
            let low = tag.lowercased()
            if name == "add_tag" {
                if !tags.contains(where: { $0.lowercased() == low }) { tags.append(tag) }
            } else {
                tags.removeAll { $0.lowercased() == low }
            }
            onStatus("Updating labels on \(it.title)…")
            do { try await store.setTags(tags, forItem: it.id) }
            catch { return ("Failed to update labels on '\(it.title)'.", []) }
            let verb = name == "add_tag" ? "Added" : "Removed"
            return ("\(verb) label '\(tag)' on '\(it.title)'. Labels now: [\(tags.joined(separator: ", "))].", [])

        case "rename_tag":
            guard let from = arg("from")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let to = arg("to")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !from.isEmpty, !to.isEmpty else { return ("Missing 'from' or 'to'.", []) }
            onStatus("Renaming label '\(from)' → '\(to)'…")
            do { try await store.renameTag(from: from, to: to) }
            catch { return ("Failed to rename label '\(from)'.", []) }
            return ("Renamed label '\(from)' to '\(to)' everywhere it was used.", [])

        case "delete_tag":
            guard let tag = arg("tag")?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty
            else { return ("Missing 'tag'.", []) }
            onStatus("Deleting label '\(tag)'…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let low = tag.lowercased()
            var removed = 0
            for (itemID, tags) in byItem where tags.contains(where: { $0.lowercased() == low }) {
                let kept = tags.filter { $0.lowercased() != low }
                if (try? await store.setTags(kept, forItem: itemID)) != nil { removed += 1 }
            }
            return removed == 0 ? ("No files carry the label '\(tag)', so nothing changed.", [])
                : ("Deleted label '\(tag)' from \(removed) file(s) — it's gone from the library.", [])

        case "merge_tags":
            guard let fromRaw = arg("from"),
                  let into = arg("into")?.trimmingCharacters(in: .whitespacesAndNewlines), !into.isEmpty
            else { return ("Missing 'from' or 'into'.", []) }
            let sources = Set(fromRaw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard !sources.isEmpty else { return ("No source labels given in 'from'.", []) }
            onStatus("Merging labels into '\(into)'…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            var planned: [(id: String, tags: [String])] = []
            for (id, tags) in byItem {
                if let newTags = Self.mergedTags(tags, from: sources, into: into) { planned.append((id, newTags)) }
            }
            let srcList = sources.sorted().joined(separator: ", ")
            guard !planned.isEmpty else { return ("No files carry any of: \(srcList). Nothing to merge.", []) }
            guard Self.boolArg(args, "confirm") else {
                return ("CONFIRM NEEDED — merge label(s) [\(srcList)] into '\(into)' across \(planned.count) file(s). " +
                        "Ask the user to confirm, then call again with confirm=true.", [])
            }
            var changed = 0
            for p in planned where (try? await store.setTags(p.tags, forItem: p.id)) != nil { changed += 1 }
            return ("Merged [\(srcList)] into '\(into)' across \(changed) file(s).", [])

        case "untagged_items":
            onStatus("Finding untagged files…")
            let limit = Int(arg("limit") ?? "") ?? 20
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let items = (try? await store.allItems()) ?? []
            let untagged = items.filter { (byItem[$0.id] ?? []).isEmpty }.prefix(max(1, min(limit, 100)))
            return untagged.isEmpty ? ("Every file has at least one label.", [])
                : ("\(untagged.count) untagged file(s): " + untagged.map(\.title).joined(separator: "; "), [])

        case "tag_search_results":
            guard let q = arg("query"),
                  let tag = arg("tag")?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty
            else { return ("Missing 'query' or 'tag'.", []) }
            onStatus("Finding files matching '\(q)'…")
            let hits = (try? await store.search(vector: embedder.embed(q), queryText: q,
                                                k: 50, keywordWeight: keywordWeight)) ?? []
            var seen = Set<String>(), targets: [(id: String, title: String)] = []
            for h in hits where seen.insert(h.item.id).inserted { targets.append((h.item.id, h.item.title)) }
            guard !targets.isEmpty else { return ("No files match '\(q)'.", []) }
            // Bulk mutation is gated like delete — preview unless explicitly confirmed.
            guard Self.boolArg(args, "confirm") else {
                return ("CONFIRM NEEDED — this will add label '\(tag)' to \(targets.count) file(s) matching '\(q)': " +
                        targets.prefix(20).map(\.title).joined(separator: "; ") +
                        ". Ask the user to confirm, then call again with confirm=true.", [])
            }
            let low = tag.lowercased()
            var applied = 0
            for t in targets {
                var tags = (try? await store.tags(forItem: t.id)) ?? []
                if !tags.contains(where: { $0.lowercased() == low }) {
                    tags.append(tag)
                    if (try? await store.setTags(tags, forItem: t.id)) != nil { applied += 1 }
                }
            }
            return ("Added label '\(tag)' to \(applied) of \(targets.count) file(s) matching '\(q)'.", [])

        case "batch_tag":
            guard let itemsRaw = arg("items"),
                  let tag = arg("tag")?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty
            else { return ("Missing 'items' or 'tag'.", []) }
            let refs = Self.parseItemList(itemsRaw)
            guard !refs.isEmpty else { return ("No file titles given in 'items'.", []) }
            onStatus("Resolving \(refs.count) file(s) to label '\(tag)'…")
            // Resolve each title; collect uniquely-resolved targets and report problems.
            var targets: [(id: String, title: String)] = []
            var resolvedIDs = Set<String>()
            var missing: [String] = [], ambiguous: [String] = []
            for ref in refs {
                let m = await resolveItems(ref)
                if m.count == 1, let it = m.first {
                    if resolvedIDs.insert(it.id).inserted { targets.append((it.id, it.title)) }
                } else if m.isEmpty { missing.append(ref) }
                else { ambiguous.append(ref) }
            }
            var notes: [String] = []
            if !missing.isEmpty { notes.append("not found: \(missing.joined(separator: ", "))") }
            if !ambiguous.isEmpty { notes.append("ambiguous (name several files): \(ambiguous.joined(separator: ", "))") }
            let noteText = notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")"
            guard !targets.isEmpty else {
                return ("Couldn't resolve any of those titles to a single file\(noteText).", [])
            }
            // Gated mutation: preview unless confirmed.
            guard Self.boolArg(args, "confirm") else {
                return ("CONFIRM NEEDED — this will add label '\(tag)' to \(targets.count) file(s): " +
                        targets.map(\.title).joined(separator: "; ") + noteText +
                        ". Ask the user to confirm, then call again with confirm=true.", [])
            }
            let low = tag.lowercased()
            var applied = 0
            for t in targets {
                var tags = (try? await store.tags(forItem: t.id)) ?? []
                if !tags.contains(where: { $0.lowercased() == low }) {
                    tags.append(tag)
                    if (try? await store.setTags(tags, forItem: t.id)) != nil { applied += 1 }
                }
            }
            return ("Added label '\(tag)' to \(applied) of \(targets.count) file(s)\(noteText).", [])

        default:
            return nil
        }
    }
}
