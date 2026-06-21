import Foundation

/// One web search result.
struct WebResult: Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

/// Gives the agent the open web. Uses SerpAPI (Google) when an API key is set for
/// rich, reliable results; otherwise falls back to a keyless DuckDuckGo HTML query
/// so web search works out of the box. Never throws — returns [] on any failure so
/// the agent degrades gracefully.
struct WebSearchClient: Sendable {
    let serpApiKey: String
    var session: URLSession = .shared

    func search(_ query: String, limit: Int = 6) async -> [WebResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if !serpApiKey.isEmpty, let r = await serpAPI(q, limit: limit), !r.isEmpty { return r }
        return await duckDuckGo(q, limit: limit)
    }

    /// Fetch a web page and return its readable text (HTML stripped) — lets the
    /// agent actually READ a result, not just its snippet. Truncated; nil on failure.
    func fetchReadable(_ urlString: String, maxChars: Int = 4000) async -> String? {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = s.hasPrefix("http") ? s : "https://" + s
        guard let url = URL(string: full), let data = try? await fetch(url) else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = Self.htmlToText(html)
        return text.isEmpty ? nil : String(text.prefix(maxChars))
    }

    /// Strip scripts/styles/tags and collapse whitespace into readable text.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for p in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>",
                  "<!--[\\s\\S]*?-->", "<[^>]+>"] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        for (e, r) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                       "&#x27;": "'", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: SerpAPI (Google)

    private func serpAPI(_ q: String, limit: Int) async -> [WebResult]? {
        var comps = URLComponents(string: "https://serpapi.com/search.json")!
        comps.queryItems = [
            .init(name: "engine", value: "google"),
            .init(name: "q", value: q),
            .init(name: "num", value: String(limit)),
            .init(name: "api_key", value: serpApiKey),
        ]
        guard let url = comps.url, let data = try? await fetch(url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organic = obj["organic_results"] as? [[String: Any]] else { return nil }
        let results = organic.prefix(limit).compactMap { r -> WebResult? in
            guard let link = r["link"] as? String else { return nil }
            return WebResult(title: (r["title"] as? String) ?? link,
                             url: link, snippet: (r["snippet"] as? String) ?? "")
        }
        return Array(results)
    }

    // MARK: DuckDuckGo HTML (keyless fallback)

    private func duckDuckGo(_ q: String, limit: Int) async -> [WebResult] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(enc)"),
              let data = try? await fetch(url, ddg: true),
              let html = String(data: data, encoding: .utf8) else { return [] }
        return Self.parseDuckDuckGo(html, limit: limit)
    }

    /// Extract (title, url, snippet) triples from DuckDuckGo's HTML results page.
    static func parseDuckDuckGo(_ html: String, limit: Int) -> [WebResult] {
        var out: [WebResult] = []
        // Result links: <a ... class="result__a" href="…">title</a>
        let linkPattern = #"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"#
        let snippetPattern = #"result__snippet\"[^>]*>(.*?)</a>"#
        let links = matches(linkPattern, in: html)
        let snippets = matches(snippetPattern, in: html)
        for (i, link) in links.enumerated() where out.count < limit {
            let rawHref = link.0
            let title = stripTags(link.1)
            let snippet = i < snippets.count ? stripTags(snippets[i].0) : ""
            let url = decodeDDGRedirect(rawHref)
            if !url.isEmpty, !title.isEmpty { out.append(WebResult(title: title, url: url, snippet: snippet)) }
        }
        return out
    }

    // MARK: helpers

    private func fetch(_ url: URL, ddg: Bool = false) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Macintosh) Mnemosyne", forHTTPHeaderField: "User-Agent")
        if ddg { req.httpMethod = "GET" }
        let (data, _) = try await session.data(for: req)
        return data
    }

    private static func matches(_ pattern: String, in text: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let g1 = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            let g2 = m.numberOfRanges > 2 && m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            return (g1, g2)
        }
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DDG wraps links as //duckduckgo.com/l/?uddg=<encoded-url>. Unwrap to the real URL.
    static func decodeDDGRedirect(_ href: String) -> String {
        guard href.contains("uddg=") else {
            return href.hasPrefix("//") ? "https:" + href : href
        }
        guard let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value else { return "" }
        return uddg
    }
}
