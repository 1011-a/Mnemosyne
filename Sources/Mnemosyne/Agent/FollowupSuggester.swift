import Foundation

/// Derives 2–3 natural follow-up questions to show as chips after an answer —
/// deepening the AI-first loop without an extra LLM round-trip. Source-grounded
/// follow-ups first (from the cited files), then useful generics.
enum FollowupSuggester {

    /// A proactive next move the agent offers after answering: a deepening QUESTION
    /// or a one-tap ACTION (build an artifact, compare sources, save a note, search
    /// the web). `send` is the text dispatched to the agent when the chip is tapped.
    struct Followup: Hashable {
        let label: String   // chip text
        let send: String    // what the agent receives
        let icon: String    // SF Symbol
        let isAction: Bool  // action chips are styled with the accent
    }

    /// Mixed follow-ups derived from the answer just given — one deepening question
    /// plus grounded ACTIONS. Fully deterministic (no extra LLM round-trip), so
    /// chips appear the instant the answer lands. Actions only surface when they'd
    /// actually do something (e.g. compare needs two distinct cited files).
    static func followups(question: String, answer: String, citations: [Citation], max: Int = 4) -> [Followup] {
        var out: [Followup] = []
        var seen = Set<String>()
        func add(_ f: Followup) {
            let key = f.label.lowercased()
            guard !seen.contains(key), out.count < max else { return }
            seen.insert(key); out.append(f)
        }

        let titles = distinctTitles(citations)
        let topic = topicPhrase(question)
        let substantial = answer.trimmingCharacters(in: .whitespacesAndNewlines).count >= 240

        // 1) Deepen — dig into the strongest cited source.
        if let first = titles.first {
            add(Followup(label: "More on \(first)", send: "Tell me more about \(first)",
                         icon: "text.magnifyingglass", isAction: false))
        }
        // 1b) Content-aware actions — when the answer surfaced DATES or FIGURES, proactively
        // offer the specialized tool for them (timeline / extract_figures) on the top source.
        // These rank above generic actions so the agent offers the RIGHT next move.
        if let firstRaw = rawTitle(citations) {
            if DateExtractor.extract(answer).count >= 2 {
                add(Followup(label: "Build a timeline", send: "Build a timeline of \(firstRaw)",
                             icon: "calendar", isAction: true))
            }
            if FigureExtractor.summary(answer) != nil {
                add(Followup(label: "Pull the figures", send: "Extract the figures from \(firstRaw)",
                             icon: "dollarsign.circle", isAction: true))
            }
        }
        // 2) Build — turn a substantial, grounded answer into a deliverable.
        if substantial, !titles.isEmpty {
            add(Followup(label: "Build a visual summary",
                         send: "Create a one-page HTML visual summary of: \(topic)",
                         icon: "wand.and.stars", isAction: true))
        }
        // 3) Compare — only meaningful with two distinct sources.
        if titles.count >= 2 {
            add(Followup(label: "Compare \(titles[0]) & \(titles[1])",
                         send: "Compare \(titles[0]) and \(titles[1])",
                         icon: "rectangle.split.2x1", isAction: true))
        }
        // 4) Save — capture a substantial synthesis back into the knowledge base.
        if substantial {
            add(Followup(label: "Save as a note",
                         send: "Save a note titled '\(noteTitle(topic))' summarising your last answer.",
                         icon: "square.and.pencil", isAction: true))
        }
        // 5) Web — always a useful escape hatch to look beyond the library.
        add(Followup(label: "Search the web", send: "Search the web for \(topic)",
                     icon: "globe", isAction: true))
        // 6) Generic deepener, to round out a thin set.
        add(Followup(label: "Key takeaways", send: "What are the key takeaways?",
                     icon: "list.bullet", isAction: false))

        return Array(out.prefix(max))
    }

    /// The actual (unmodified) title of the first cited source — used in tool commands
    /// that resolve a file by its real name (timeline / extract_figures). nil if none.
    static func rawTitle(_ citations: [Citation]) -> String? {
        citations.first { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }?.title
    }

    /// Distinct human-readable cited file names, in citation order (max 3).
    static func distinctTitles(_ citations: [Citation], limit: Int = 3) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for c in citations {
            let name = displayTitle(c.title)
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key); out.append(name)
            if out.count == limit { break }
        }
        return out
    }

    /// A compact topic phrase for action prompts — the question minus trailing
    /// punctuation, trimmed to a reasonable length.
    static func topicPhrase(_ question: String, maxChars: Int = 80) -> String {
        let q = question.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n?？.。!！"))
        if q.isEmpty { return "this topic" }
        return q.count <= maxChars ? q : String(q.prefix(maxChars)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A short, file-safe-ish note title from a topic phrase.
    static func noteTitle(_ topic: String, maxChars: Int = 40) -> String {
        let t = topic.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        let base = t.isEmpty ? "Summary" : t
        return base.count <= maxChars ? base : String(base.prefix(maxChars)).trimmingCharacters(in: .whitespaces)
    }

    static func suggest(question: String, citations: [Citation], max: Int = 3) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let key = s.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key); out.append(s)
        }

        // Source-grounded: dig into the top distinct cited files.
        var usedTitles = Set<String>()
        for c in citations {
            let name = displayTitle(c.title)
            guard !name.isEmpty, !usedTitles.contains(name.lowercased()) else { continue }
            usedTitles.insert(name.lowercased())
            add("Tell me more about \(name)")
            if usedTitles.count == 2 { break }
        }

        // Useful generics to round out the set.
        add("What are the key takeaways?")
        add("How does this relate to my other files?")

        return Array(out.prefix(max))
    }

    /// A human title: drop the extension, turn separators into spaces.
    static func displayTitle(_ raw: String) -> String {
        var name = raw
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            // only strip a short, file-like extension
            let ext = name[name.index(after: dot)...]
            if ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                name = String(name[..<dot])
            }
        }
        return name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
