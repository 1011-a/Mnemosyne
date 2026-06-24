import Foundation

/// Saved-search tool handlers (save / list / run / delete), extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. Store-coupled (they read and write the saved-search
/// table and `run_saved_search` retrieves + renders hits), so they live in an `extension ToolAgent`
/// rather than migrating to Fathom. `handleSavedSearchTool` returns nil when `name` isn't one of
/// these, letting the caller fall through.
extension ToolAgent {
    func handleSavedSearchTool(_ name: String, args: String, citationOffset: Int,
                               onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "save_search":
            guard let name = arg("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let query = arg("query")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty
            else { return ("Missing 'name' or 'query'.", []) }
            onStatus("Saving search '\(name)'…")
            // Reuse an existing entry's id when the name matches, so re-saving updates it.
            let existing = Self.matchSavedSearch(name, in: (try? await store.allSavedSearches()) ?? [])
            let s = SavedSearch(id: existing?.id ?? UUID().uuidString, name: name, query: query, kinds: [], tag: nil)
            do { try await store.saveSearch(s) } catch { return ("Couldn't save the search.", []) }
            return ("Saved search '\(name)' → “\(query)”. Run it later with run_saved_search.", [])

        case "list_saved_searches":
            onStatus("Reading saved searches…")
            let searches = (try? await store.allSavedSearches()) ?? []
            guard !searches.isEmpty else { return ("You have no saved searches yet.", []) }
            return ("\(searches.count) saved search(es):\n" +
                    searches.map { "• \($0.name) → “\($0.query)”" }.joined(separator: "\n"), [])

        case "run_saved_search":
            guard let ref = arg("search") else { return ("Missing 'search'.", []) }
            let searches = (try? await store.allSavedSearches()) ?? []
            guard let s = Self.matchSavedSearch(ref, in: searches) else {
                return searches.isEmpty ? ("You have no saved searches yet.", [])
                    : ("No saved search matches '\(ref)'. You have: \(searches.map(\.name).joined(separator: ", ")).", [])
            }
            onStatus("Running saved search '\(s.name)'…")
            let hits = (try? await store.search(vector: embedder.embed(s.query), queryText: s.query,
                                                k: topK, keywordWeight: keywordWeight)) ?? []
            guard !hits.isEmpty else { return ("Saved search '\(s.name)' (“\(s.query)”) matched nothing.", []) }
            return render(hits, startingAt: citationOffset)

        case "delete_saved_search":
            guard let ref = arg("search") else { return ("Missing 'search'.", []) }
            let searches = (try? await store.allSavedSearches()) ?? []
            guard let s = Self.matchSavedSearch(ref, in: searches) else {
                return ("No saved search matches '\(ref)'.", [])
            }
            onStatus("Deleting saved search '\(s.name)'…")
            do { try await store.deleteSavedSearch(id: s.id) } catch { return ("Couldn't delete it.", []) }
            return ("Deleted saved search '\(s.name)'.", [])

        default:
            return nil
        }
    }
}
