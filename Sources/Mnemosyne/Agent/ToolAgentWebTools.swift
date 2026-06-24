import Foundation

/// Web tool handlers — live web search, deep multi-source web research, term definition, and single
/// URL fetch — extracted from `ToolAgent`'s main `handleTool` switch to keep that file focused.
/// Network-coupled (drive the WebSearchClient and return cited web evidence), so they live in an
/// `extension ToolAgent` rather than migrating to Fathom. `handleWebTool` returns nil when `name`
/// isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleWebTool(_ name: String, args: String, citationOffset: Int,
                       onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "web_search":
            guard let q = arg("query") else { return ("Missing 'query'.", []) }
            guard let webSearch else { return ("Web search isn't available right now.", []) }
            onStatus("Searching the web: \(q)")
            let results = await webSearch.search(q, limit: 6)
            guard !results.isEmpty else { return ("No web results for '\(q)'.", []) }
            var text = "", cites: [Citation] = []
            for (i, r) in results.enumerated() {
                let n = citationOffset + i + 1
                text += "[\(n)] (\(r.title)) \(r.url)\n\(r.snippet)\n"
                cites.append(Citation(index: n, title: r.title, path: r.url, snippet: r.snippet))
            }
            return (text, cites)

        case "web_research":
            guard let q = arg("query") else { return ("Missing 'query'.", []) }
            guard let ws = webSearch else { return ("Web search isn't available right now.", []) }
            let depth = Swift.min(Swift.max(Int(arg("depth") ?? "") ?? 3, 1), 5)
            onStatus("Researching the web: \(q)")
            let results = await ws.search(q, limit: Swift.max(depth, 6))
            guard !results.isEmpty else { return ("No web results for '\(q)'.", []) }
            let top = Array(results.prefix(depth))
            // Read the top pages in PARALLEL — the win over sequential fetch_url calls.
            let bodies = await withTaskGroup(of: (Int, String?).self) { group -> [Int: String] in
                for (i, r) in top.enumerated() {
                    group.addTask { (i, await ws.fetchReadable(r.url, maxChars: 2500)) }
                }
                var acc: [Int: String] = [:]
                for await (i, body) in group { if let body { acc[i] = body } }
                return acc
            }
            onStatus("")
            // Fall back to a result's snippet when its page wasn't readable.
            let sources = top.enumerated().map { (i, r) in
                (title: r.title, url: r.url, body: bodies[i] ?? r.snippet)
            }
            return Self.researchDigest(query: q, sources: sources, citationOffset: citationOffset)

        case "define_term":
            guard let term = arg("term") else { return ("Missing 'term'.", []) }
            onStatus("Looking up \(term)…")
            // KB-first: only treat the library as authoritative if the top hit clears
            // a relevance bar — otherwise a weak local match would suppress the web.
            let local = (try? await store.search(vector: embedder.embed(term), queryText: term,
                                                 k: 4, keywordWeight: keywordWeight)) ?? []
            if Self.kbClears(topScore: local.first?.score) {
                let (text, cites) = render(local, startingAt: citationOffset)
                return ("Defining \u{201C}\(term)\u{201D} from YOUR library:\n\(text)\nDefine the term using these sources, citing [n].", cites)
            }
            // Web fallback.
            if let ws = webSearch {
                let results = await ws.search(term, limit: 4)
                if !results.isEmpty {
                    var text = "", cites: [Citation] = []
                    for (i, r) in results.enumerated() {
                        let n = citationOffset + i + 1
                        text += "[\(n)] (\(r.title)) \(r.url)\n\(r.snippet)\n"
                        cites.append(Citation(index: n, title: r.title, path: r.url, snippet: r.snippet))
                    }
                    return ("\u{201C}\(term)\u{201D} isn't in your library — defining it from the WEB:\n\(text)\nGive a concise definition, citing [n].", cites)
                }
            }
            return ("Couldn't find \u{201C}\(term)\u{201D} in your library, and web search is unavailable or returned nothing.", [])

        case "fetch_url":
            guard let url = arg("url") else { return ("Missing 'url'.", []) }
            let client = webSearch ?? WebSearchClient(serpApiKey: "")
            onStatus("Reading \(url)…")
            guard let text = await client.fetchReadable(url) else {
                return ("Couldn't read \(url) (unreachable or empty).", [])
            }
            let n = citationOffset + 1
            return ("[\(n)] (\(url))\n\(text)\n",
                    [Citation(index: n, title: url, path: url, snippet: String(text.prefix(200)))])

        default:
            return nil
        }
    }
}
