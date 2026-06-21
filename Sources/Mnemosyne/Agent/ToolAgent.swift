import Foundation
import AppKit
import Fathom

/// Agentic brain: instead of one-shot RAG, DeepSeek drives a tool-calling loop.
/// It can call `search_knowledge` as many times as it needs (multi-hop) to
/// gather evidence before answering — better for comparative / multi-part
/// questions. Every retrieved source becomes a numbered citation.
struct ToolAgent: Sendable {
    let store: KnowledgeStore
    let embedder: Embedder
    let deepSeek: DeepSeekClient
    var topK: Int = 6
    var temperature: Double = 0.3
    var keywordWeight: Float = 0.3
    var maxRounds: Int = 4
    /// Run a reviewer pass after the act phase (orchestration: plan → act → verify).
    var critic: Bool = true
    /// Re-extract + re-embed a file by path (plumbed from the Ingestor). nil when
    /// re-ingest isn't available (e.g. tests), in which case the tool degrades.
    var onReingest: (@Sendable (String) async -> Void)? = nil
    /// Open-web search (SerpAPI or keyless fallback). nil ⇒ web search unavailable.
    var webSearch: WebSearchClient? = nil
    /// Which engine builds artifacts (create_artifact). DeepSeek-native by default.
    var buildEngine: BuildEngine = .deepseek
    /// Persistent deferred-task list (add_reminder / list_reminders / complete_reminder).
    var reminders: ReminderStore = ReminderStore()
    /// Conversation token budget before the oldest turns are compacted into a summary.
    var contextBudget: Int = ContextManager.defaultBudgetTokens
    /// Override the LLM transport for the tool-calling loop. nil ⇒ the loop talks to
    /// DeepSeek through `AgentLLMClient` (the SDK). Tests inject a scripted mock here so
    /// the agentic loop runs deterministically, offline.
    var llmOverride: (any Fathom.LLMClient)? = nil

    /// The LLM client the ACT loop calls each round (the SDK transport, by default).
    private var llm: any Fathom.LLMClient {
        llmOverride ?? AgentLLMClient(deepSeek: deepSeek, temperature: temperature)
    }

    /// What the critic decides after reviewing the gathered evidence.
    enum CriticAction: Equatable { case ok, search(String), note(String) }

    /// Why the tool-calling loop ended (drives a trace note for the user).
    enum FinishReason: Equatable { case natural, noProgress, roundLimit }

    /// A short trace line explaining a non-obvious finish — nil when the agent
    /// stopped cleanly on its own (no note needed).
    static func finishTrace(_ r: FinishReason) -> String? {
        switch r {
        case .natural:    return nil
        case .noProgress: return "Wrapping up — no new information in the last steps."
        case .roundLimit: return "Reached the step limit — answering with what I have."
        }
    }

    static let criticPrompt = """
    You are a STRICT reviewer of a knowledge agent, before it answers. Look at the user's question \
    and the search results gathered so far. Reply with EXACTLY ONE line, nothing else:
    • "SEARCH: <query>" — if one specific additional search would likely surface a directly-relevant \
      file that is clearly missing (e.g. an exact name or term not yet searched).
    • "NOTE: <one short sentence>" — if the evidence is insufficient, conflicting, or the planned \
      action looks unsafe, so the answer must hedge or refuse.
    • "OK" — if the gathered evidence is sufficient to answer accurately.
    """

    /// Tools that change the knowledge base — used to skip the question-oriented
    /// critic/seed when the user asked for an action.
    static let mutationTools: Set<String> = [
        "add_tag", "remove_tag", "rename_tag", "delete_tag", "delete_item",
        "tag_search_results", "batch_tag", "reingest", "save_note",
        "save_search", "delete_saved_search",
        "add_reminder", "complete_reminder", "merge_tags", "suggest_labels", "auto_label_untagged",
        "pin_fact", "unpin_fact",
    ]

    /// Heuristic: does the request read as an ACTION (manage the library) rather
    /// than a question? Covers English + common Chinese verbs. When unsure we lean
    /// "action" — that only skips the optional search seed, which is harmless.
    static func looksLikeAction(_ query: String) -> Bool {
        let q = query.lowercased()
        let verbs = ["add ", "remove", "delete", "rename", "untag", "retag", "re-tag",
                     "open ", "reveal", "reingest", "re-ingest", "reindex", "clean up",
                     "organize", "organise", "tidy", "create ", "build ", "generate ", "make a", "make an",
                     "update ", "revise", "rebuild", "save a note", "save note",
                     // Approval/continuation of a previewed action (so it re-invokes the
                     // pending tool instead of being re-seeded as a fresh question).
                     "apply", "approve", "go ahead", "confirm", "proceed",
                     "删除", "移除", "去掉", "重命名", "改名", "添加", "加上", "整理", "清理", "打开", "标记",
                     "创建", "制作", "生成", "做一个", "做个", "更新", "修改", "重建", "确认", "应用", "批准"]
        return verbs.contains { q.contains($0) }
    }

    static let plannerPrompt = """
    You are a PLANNER for a knowledge desktop agent. It can: search the indexed files (search_knowledge, \
    get_item, find_by_tag, related_items, recent_items); manage labels (add_tag/remove_tag/rename_tag/delete_tag, \
    merge_tags, tag_search_results, suggest_labels, auto_label_untagged); inspect the library (library_stats, \
    library_health, tag_stats, find_duplicates); read documents (summarize_item, outline_item, keyword_extract, \
    extract_links, diff_items); use the open web (web_search, fetch_url, web_research, define_term); compute \
    exactly (calculate, unit_convert); remember durable facts (pin_fact); build deliverables (create_artifact); \
    and save notes (save_note). Break the user's GOAL into 2-6 concrete, ORDERED steps, each naming the tool(s) \
    it will use. Prefer web_research for deep web answers and calculate for any math. Output ONLY a numbered \
    list — one step per line, no preamble, no commentary.
    """

    /// A goal is "complex" (worth an explicit plan + a bigger round budget) when it
    /// is long or chains multiple actions. Covers English + Chinese cues.
    static func isComplexGoal(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        let lower = query.lowercased()
        let cues = ["then ", "after that", "and also", "step by step", "first ", "finally",
                    "然后", "之后", "接着", "并且", "分步", "最后", "首先", "再"]
        return words >= 14 || cues.contains { lower.contains($0) }
    }

    /// Parse a numbered/bulleted plan into clean step strings.
    static func parsePlan(_ text: String) -> [String] {
        func strip(_ t: String) -> String {
            t.replacingOccurrences(of: #"^\d+[\.\)]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-•*]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Prefer genuine LIST ITEMS (numbered or bulleted) when the model used a list —
        // this drops the conversational preamble ("Here's the plan:") and closing remarks
        // ("Let me get started!") that would otherwise inflate the step count + round budget.
        let marked = lines.filter {
            $0.range(of: #"^(\d+[\.\)]|[-•*])\s+"#, options: .regularExpression) != nil
        }
        let source = marked.count >= 2 ? marked : lines
        // De-duplicate (case-insensitive), preserving order — repeated steps waste rounds.
        var seen = Set<String>(); var out: [String] = []
        for line in source {
            let s = strip(line)
            guard s.count >= 3, seen.insert(s.lowercased()).inserted else { continue }
            out.append(s)
        }
        return out
    }

    /// Parse the reviewer's single-line decision.
    static func parseCriticDecision(_ text: String) -> CriticAction {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = t.uppercased()
        if upper.hasPrefix("SEARCH:") {
            let q = t.dropFirst("SEARCH:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? .ok : .search(q)
        }
        if upper.hasPrefix("NOTE:") {
            let n = t.dropFirst("NOTE:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? .ok : .note(n)
        }
        return .ok
    }

    struct Answer: Sendable {
        let text: String
        let citations: [Citation]
        let searches: Int
    }

    static let systemPrompt = """
    You are Mnemosyne, a personal-knowledge DESKTOP AGENT acting on the user's own indexed files on \
    this Mac. You don't just answer — you can inspect and MANAGE the knowledge base with tools:
    • search_knowledge(query) — semantic + keyword search; returns numbered sources.
    • get_item(item) — the full text and metadata of ONE file, identified by its title.
    • list_tags() — every label and how many items carry it.
    • find_by_tag(tag) — the items carrying a label.
    • library_stats() — totals and a breakdown by file kind.
    • add_tag(item, tag) / remove_tag(item, tag) — manage an item's labels.
    • web_search(query) — search the OPEN WEB; fetch_url(url) — READ a full web page; cite web sources too.
    • web_research(query) — DEEP multi-source web answer in ONE call; prefer it over web_search+fetch_url for depth.
    • create_artifact(task) — build a deliverable; save_note(title, content) — write findings back into the KB.
    • calculate(expr) / unit_convert(value,from,to) — do math and conversions EXACTLY; never compute in your head.
    • summarize_item / outline_item / keyword_extract — condense, outline, or fingerprint a large file.
    • extract_action_items(item) — pull TODOs/tasks/commitments out of a note; proactively offer to add_reminder for each.
    • timeline(item) — list a file's dates in chronological order (a contract/project/history timeline).
    • extract_figures(item) — pull monetary amounts and percentages from a file (invoices, budgets, reports).
    • extract_phone_numbers(item) — pull phone numbers from a file (contacts), alongside extract_emails.
    • extract_questions(item) — pull the questions a file raises (FAQ / study / interview prep).
    • extract_acronyms(item) — pull acronyms (+ expansions when present) to build a glossary.
    • extract_code_blocks(item) — pull fenced code snippets (with language) from a file.
    • extract_contacts(item) — one-call roll-up of the people, emails, and phones in a file.
    • entity_extract(item) — list the people, organizations, and places mentioned in a file (on-device).
    • sentiment(item) — gauge the emotional tone (−1…+1) of a file: reviews, feedback, journal entries.
    • find_by_date(start,end,field) — list files whose created/modified date falls in an explicit range.
    • detect_language(item) — identify what language a file is written in (on-device); use before translate.
    • readability(item) — Flesch reading-ease (0 hard … 100 easy) to triage how dense a document is.
    • pin_fact(fact) — save a DURABLE user fact (name, preferences) to long-term memory so you always recall it.
    • library_health / find_duplicates / find_similar_titles / merge_tags / auto_label_untagged — diagnose and tidy the library.
    • library_languages — break the whole library down by language (e.g. English vs Chinese share).
    • catch_me_up — a proactive briefing: recent changes, due/overdue reminders, and tidy-up nudges.
    • most_cited — the files you reference most in conversations (your go-to sources).
    • activity_trend — file activity over the last N days (total, busiest day, recent pace).
    • save_search / list_saved_searches / run_saved_search / delete_saved_search — name and recall searches.
    • search_conversations(query) — find past chats that discussed a topic ("did we talk about X before").
    • suggest_connections(item) — find related-but-unlabelled-together files to propose linking (autonomous).
    • suggest_tags_from_neighbors(item) — propose labels from what the file's most similar files are tagged.
    Work in three phases — PLAN, ACT, then answer:
    1. PLAN: decide if the request is a QUESTION (needs evidence) or an ACTION (manage the KB), and \
       which tool(s) it needs.
    2. ACT: call tools. For questions, search (several phrasings for multi-part questions). For \
       actions, call the management tool. Identify a file by title; if a name matches several files, \
       list them and ask which — never guess.
    3. ANSWER: from QUESTIONS, cite every claim inline as [1], [2] matching the source numbers; use \
       ONLY returned sources and say so if nothing is found. From ACTIONS, confirm in ONE sentence \
       exactly what you did.
    LABELS: to delete a label from ONE file use remove_tag; to delete a label from the WHOLE library \
    use delete_tag; to rename one use rename_tag. When the user says "delete/remove the X label" without \
    naming a file, they mean delete_tag (the whole library). ALWAYS actually call the tool — never just \
    say you did it. If unsure which label exists, call list_tags first.
    SAFETY: destructive / bulk actions are two-step — delete_item, tag_search_results, batch_tag, merge_tags, and \
    auto_label_untagged first PREVIEW (call without confirm/apply). Relay the preview, get the user's explicit \
    "yes", then call again with confirm=true / apply=true. Never mutate on a vague request.
    BEST PRACTICE: don't repeat a tool call you already made; if two steps find nothing new, answer with what \
    you have and be honest about gaps. Use calculate for any arithmetic. When the user states a durable fact \
    about themselves, offer to pin_fact it.
    Match the user's language. Be concise: a summary sentence, then short "- " bullets if needed.
    """

    // Tools are built fresh each call — a static `[String: Any]` isn't Sendable in Swift 6.
    static func tools() -> [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "function", "function": [
                "name": name, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": required]]]
        }
        let item: [String: Any] = ["type": "string", "description": "The title (or a distinctive part of it) of the target file."]
        let tag: [String: Any] = ["type": "string", "description": "A label/tag name."]
        return [
            tool("search_knowledge", "Semantic + keyword search over the user's files. Returns numbered source snippets.",
                 ["query": ["type": "string", "description": "A focused natural-language search query."]], required: ["query"]),
            tool("get_item", "Return the full extracted text and metadata of ONE file, found by title.",
                 ["item": item], required: ["item"]),
            tool("summarize_item", "Pull the ENTIRE text of one (possibly large) file and summarize it — more complete than get_item (which truncates). Use when the user asks to summarize/condense/TL;DR a specific document.",
                 ["item": item], required: ["item"]),
            tool("outline_item", "Extract the heading/section OUTLINE (table of contents) of a file — markdown headings, numbered sections, ALL-CAPS headers. Use to grasp a long document's structure before reading it.",
                 ["item": item], required: ["item"]),
            tool("keyword_extract", "Surface a file's most salient TERMS by frequency (a quick topical fingerprint) — useful to suggest labels or grasp what a document is about at a glance.",
                 ["item": item], required: ["item"]),
            tool("extract_links", "Pull all the web LINKS (http/https URLs) out of a file — for collecting references or following sources.",
                 ["item": item], required: ["item"]),
            tool("extract_dates", "Pull all DATES (ISO, slashed, or month-name) out of a file — for finding deadlines or events, e.g. to set reminders.",
                 ["item": item], required: ["item"]),
            tool("timeline", "List the dates in a file in CHRONOLOGICAL order (earliest first) — build a timeline of a contract, project log, or history. Unlike extract_dates (document order).",
                 ["item": item], required: ["item"]),
            tool("extract_emails", "Pull all EMAIL addresses out of a file — for collecting contacts.",
                 ["item": item], required: ["item"]),
            tool("extract_phone_numbers", "Pull all PHONE NUMBERS out of a file (international, US-parens, or separated forms) — for collecting contacts, alongside extract_emails.",
                 ["item": item], required: ["item"]),
            tool("extract_contacts", "One-call CONTACTS roll-up for a file: the people, emails, and phone numbers found, grouped together. Use for 'who do I contact in this file' instead of calling entity_extract + extract_emails + extract_phone_numbers separately.",
                 ["item": item], required: ["item"]),
            tool("extract_action_items", "Pull actionable TASKS / TODOs / commitments out of a file — checkbox items, TODO/FIXME/ACTION markers, and 'need to / must / follow up / remember to' phrasing. Use to turn notes into follow-ups (then optionally add_reminder for each).",
                 ["item": item], required: ["item"]),
            tool("extract_figures", "Pull monetary AMOUNTS ($1,234.56, 50 USD, €10) and PERCENTAGES (15%) out of a file — for invoices, contracts, budgets, reports ('what amounts are in this file').",
                 ["item": item], required: ["item"]),
            tool("extract_questions", "Pull the QUESTIONS out of a file — turn a document into an FAQ, study deck, or interview-prep list ('what questions does this raise/ask').",
                 ["item": item], required: ["item"]),
            tool("extract_acronyms", "Pull the ACRONYMS / initialisms out of a file (API, HTTP, TCP…) and their spelled-out expansions when present — build a glossary or decode jargon.",
                 ["item": item], required: ["item"]),
            tool("extract_code_blocks", "Pull the fenced CODE SNIPPETS (```lang … ```) out of a file, with their language — 'show me the code in this doc', build a snippet library.",
                 ["item": item], required: ["item"]),
            tool("entity_extract", "Pull the NAMED ENTITIES (people, organizations, places) mentioned in a file — answer 'who/what is mentioned here', build contact or topic lists. On-device, offline.",
                 ["item": item], required: ["item"]),
            tool("sentiment", "Gauge the emotional TONE of a file (how positive/negative) — useful for reviews, feedback, or journal entries. Returns a label and a −1…+1 score. On-device, offline.",
                 ["item": item], required: ["item"]),
            tool("detect_language", "Detect what LANGUAGE a file is written in (with confidence) — useful before translating, or to triage a multilingual library. On-device, offline.",
                 ["item": item], required: ["item"]),
            tool("reading_time", "Estimate how long a file takes to read — word count and minutes (~220 wpm).",
                 ["item": item], required: ["item"]),
            tool("readability", "Score how DENSE / approachable a file is — Flesch reading-ease (0 hard … 100 easy) with a grade band. Pairs with reading_time to triage a quick skim vs. a slog. English-oriented; on-device.",
                 ["item": item], required: ["item"]),
            tool("suggest_labels", "Propose 3-5 LABELS for a file from its salient terms, reusing existing library labels where they fit. Previews by default; pass apply=true to actually add them.",
                 ["item": item, "apply": ["type": "boolean", "description": "Set true to ADD the suggested labels. Omit/false = preview only."]],
                 required: ["item"]),
            tool("suggest_tags_from_neighbors", "Propose LABELS for a file from what its most SIMILAR files are already tagged (a collaborative signal) — complements suggest_labels (which uses the file's own terms). Best for tagging a new file consistently with the rest of the library. Preview; apply with add_tag.",
                 ["item": item], required: ["item"]),
            tool("auto_label_untagged", "BATCH organize: find untagged files and propose labels for EACH from its content (reusing existing labels). Previews by default; pass apply=true to label them all.",
                 ["limit": ["type": "integer", "description": "Max files to process (default 10)."],
                  "apply": ["type": "boolean", "description": "Set true to APPLY labels to all proposed files. Omit/false = preview."]]),
            tool("list_tags", "List every label/tag in the knowledge base with the number of items carrying each.", [:]),
            tool("save_search", "SAVE a search query under a name so it can be re-run later — e.g. save 'unpaid invoices' as 'invoices'. Use when the user says 'save this search' or 'remember this query'.",
                 ["name": ["type": "string", "description": "A short name for the saved search."],
                  "query": ["type": "string", "description": "The search query to save."]],
                 required: ["name", "query"]),
            tool("list_saved_searches", "List the user's saved searches (their names and queries).", [:]),
            tool("search_conversations", "Search the user's PAST CONVERSATIONS (chat titles and messages) — 'did we talk about X before', 'find that chat about Y'. Returns matching threads with dates.",
                 ["query": ["type": "string", "description": "What to look for across past chats."]],
                 required: ["query"]),
            tool("run_saved_search", "Run a previously SAVED search by its name and return the matching files (cited).",
                 ["search": ["type": "string", "description": "Name (or part) of the saved search to run."]],
                 required: ["search"]),
            tool("delete_saved_search", "Delete a saved search by its name.",
                 ["search": ["type": "string", "description": "Name (or part) of the saved search to delete."]],
                 required: ["search"]),
            tool("tag_stats", "Label ANALYTICS: per-label usage counts AND which labels frequently appear together (co-occurrence). Use to understand how the library is organized or to spot related topics.", [:]),
            tool("find_by_tag", "List the files that carry a given label/tag.", ["tag": tag], required: ["tag"]),
            tool("summarize_tag", "Summarize ALL files carrying a label into ONE cohesive overview, with citations. Use for 'summarize my <label> notes'.",
                 ["tag": tag], required: ["tag"]),
            tool("library_stats", "Totals (items, chunks) and a breakdown of the knowledge base by file kind.", [:]),
            tool("most_cited", "List the files you REFERENCE MOST in conversations (by how often they've been cited) — your go-to / most-relied-upon sources.",
                 ["limit": ["type": "integer", "description": "How many to list (default 5)."]]),
            tool("activity_trend", "Summarize file ACTIVITY over the last N days — total changes, the busiest day, and recent pace. Use for 'how active have I been', 'when did I add the most'.",
                 ["days": ["type": "integer", "description": "Window in days (default 30)."]]),
            tool("summarize_library", "A one-call DIGEST of the whole knowledge base — totals, kind breakdown, top labels, untagged count, and the newest files. Use for 'what's in my library / give me an overview' or before suggesting what to do next.", [:]),
            tool("library_health", "A one-call HEALTH CHECK — label coverage, untagged count, near-duplicate labels — with concrete cleanup recommendations (auto_label_untagged, merge_tags). Use for 'how organized is my library / what should I clean up'.", [:]),
            tool("find_duplicates", "Find sets of files with IDENTICAL content (exact duplicates) — useful before deleting redundant items.", [:]),
            tool("find_similar_titles", "Find sets of files with NEAR-DUPLICATE names (versioned or copied — e.g. 'Report final.pdf' vs 'Report final v2.pdf', 'notes (1).txt') even when their content differs. Library hygiene; complements find_duplicates (which needs identical content).", [:]),
            tool("library_themes", "Surface the DOMINANT TOPICS across the whole library (terms appearing in many files) — for 'what are the main themes in my knowledge' or to suggest what to explore.", [:]),
            tool("library_languages", "Break down the WHOLE library by LANGUAGE — what share of files are English vs Chinese vs … — for a multilingual collection. On-device detection.",
                 ["limit": ["type": "integer", "description": "Max files to sample (default 300)."]]),
            tool("catch_me_up", "A proactive BRIEFING: what changed recently, which reminders are due/overdue, and any tidy-up nudges — answer 'catch me up', 'what's new', 'what should I look at'.",
                 ["days": ["type": "integer", "description": "Look-back/look-ahead window in days (default 7)."]]),
            tool("find_by_kind", "List files of a given KIND/type — pdf, image, markdown, text, code, webpage, email, word.",
                 ["kind": ["type": "string", "description": "e.g. 'pdf', 'image', 'markdown'."]], required: ["kind"]),
            tool("add_tag", "Add a label to a file.", ["item": item, "tag": tag], required: ["item", "tag"]),
            tool("remove_tag", "Remove a label from a file.", ["item": item, "tag": tag], required: ["item", "tag"]),
            tool("rename_tag", "Rename a label everywhere it is used.",
                 ["from": ["type": "string", "description": "Existing label name."],
                  "to": ["type": "string", "description": "New label name."]], required: ["from", "to"]),
            tool("delete_tag", "Delete a label ENTIRELY — remove it from every file that has it (the label disappears from the library).",
                 ["tag": tag], required: ["tag"]),
            tool("merge_tags", "Consolidate several messy/duplicate labels into ONE (e.g. 'ml, machine-learning, ML' → 'machine learning'). Bulk + safe: requires confirm=true; without it, previews how many files are affected.",
                 ["from": ["type": "string", "description": "Comma-separated source labels to merge (e.g. 'ml, machine-learning')."],
                  "into": ["type": "string", "description": "The single target label they all become."],
                  "confirm": ["type": "boolean", "description": "Must be true to apply. Omit/false = preview the affected count."]],
                 required: ["from", "into"]),
            tool("recent_items", "List the most recently added/modified files.",
                 ["limit": ["type": "integer", "description": "How many to list (default 10)."]]),
            tool("largest_items", "List the BIGGEST files by size (storage triage) — useful for finding bulky items.",
                 ["limit": ["type": "integer", "description": "How many to list (default 10)."]]),
            tool("oldest_items", "List the OLDEST files (least recently added/modified) — for finding stale content to review.",
                 ["limit": ["type": "integer", "description": "How many to list (default 10)."]]),
            tool("recent_changes", "List files changed/added within a TIME WINDOW — the last N days (default 7) or since a given date. Use for 'what changed this week', 'what's new since June 1'.",
                 ["days": ["type": "integer", "description": "Look-back window in days (default 7). Ignored if 'since' is set."],
                  "since": ["type": "string", "description": "Optional ISO date (YYYY-MM-DD) to count changes from."]]),
            tool("find_by_date", "List files whose date falls in an explicit RANGE — e.g. 'what did I save between March 1 and May 31', 'files created in 2025'. Either bound may be omitted for an open-ended range.",
                 ["start": ["type": "string", "description": "Start ISO date (YYYY-MM-DD), inclusive. Omit for no lower bound."],
                  "end": ["type": "string", "description": "End ISO date (YYYY-MM-DD), inclusive (whole day). Omit for no upper bound."],
                  "field": ["type": "string", "description": "Which date to filter on: 'modified' (default) or 'created'."],
                  "limit": ["type": "integer", "description": "Max files to list (default 25)."]]),
            tool("related_items", "Find files semantically related to a given file.", ["item": item], required: ["item"]),
            tool("suggest_connections", "AUTONOMOUS suggestion: for a file, surface semantically-related files that share NO label with it — content you could connect but haven't yet. Offer to co-tag them. Great for 'what should I link to this'.",
                 ["item": item], required: ["item"]),
            tool("reveal_in_finder", "Reveal a file in macOS Finder (opens Finder, selects the file).", ["item": item], required: ["item"]),
            tool("open_file", "Open a file with its default macOS application.", ["item": item], required: ["item"]),
            tool("delete_item", "Remove a file from the knowledge base ONLY (the file on disk is untouched). DESTRUCTIVE: requires the EXACT title AND confirm=true. Call once WITHOUT confirm to preview; only call with confirm=true after the user agrees.",
                 ["item": item, "confirm": ["type": "boolean", "description": "Must be true to actually delete. Omit or false = preview only."]], required: ["item"]),
            tool("untagged_items", "List files that have no labels yet (useful for tidying up).",
                 ["limit": ["type": "integer", "description": "How many to list (default 20)."]]),
            tool("tag_search_results", "Add a label to EVERY file matching a search query (bulk). Requires confirm=true; without it, previews the matches first.",
                 ["query": ["type": "string", "description": "Search query selecting the files to label."],
                  "tag": tag,
                  "confirm": ["type": "boolean", "description": "Must be true to apply. Omit/false = preview the matched files."]],
                 required: ["query", "tag"]),
            tool("batch_tag", "Add ONE label to SEVERAL specific files named by title, in one confirmed action — e.g. to co-tag the files from suggest_connections. Requires confirm=true; without it, previews which titles resolve (and flags any missing/ambiguous).",
                 ["items": ["type": "string", "description": "Comma-separated file titles to label."],
                  "tag": tag,
                  "confirm": ["type": "boolean", "description": "Must be true to apply. Omit/false = preview which files would be labelled."]],
                 required: ["items", "tag"]),
            tool("reingest", "Re-read a file from disk and re-index it (use after the file changed on disk).",
                 ["item": item], required: ["item"]),
            tool("web_search", "Search the OPEN WEB for current information not in the user's files. Returns numbered web sources you can cite. Use it for recent events, definitions, or to augment local knowledge.",
                 ["query": ["type": "string", "description": "A focused web search query."]], required: ["query"]),
            tool("web_research", "DEEP web research in ONE call: searches the web, then fetches and reads the FULL text of the top sources in parallel, returning a combined corpus to synthesize a grounded, cited answer. Prefer this over web_search+fetch_url when you need depth (how/why questions, comparisons, current state of a topic).",
                 ["query": ["type": "string", "description": "The research question or topic."],
                  "depth": ["type": "integer", "description": "How many sources to read in full (1-5, default 3)."]],
                 required: ["query"]),
            tool("define_term", "Quickly DEFINE/look up a term — checks the user's OWN library first, and only falls back to the web if it isn't found locally. Use for 'what is X', 'define X', glossary lookups.",
                 ["term": ["type": "string", "description": "The term or concept to define."]], required: ["term"]),
            tool("create_artifact", "Build a real DELIVERABLE from the user's knowledge — an HTML report/dashboard, a visualization, code, or a mini-app — by delegating to a developer build agent. Saves files to ~/Documents/Mnemosyne Artifacts and reveals them. Use when the user asks to 'create/build/make/generate' something, or to REVISE a past artifact (pass `revise`).",
                 ["task": ["type": "string", "description": "What to build, or how to change it when revising."],
                  "revise": ["type": "string", "description": "Optional: the TITLE of an existing artifact to update in place (use after read_artifact / list_recent_artifacts)."]],
                 required: ["task"]),
            tool("fetch_url", "Fetch and READ the full text of a web page (beyond a search snippet). Use after web_search to read a promising result, or when the user gives a URL.",
                 ["url": ["type": "string", "description": "The page URL to read."]], required: ["url"]),
            tool("save_note", "Save synthesized findings BACK into the user's knowledge base as a searchable note (a .md file in ~/Documents/Mnemosyne Notes). Use when the user asks to remember/save a summary or conclusion.",
                 ["title": ["type": "string", "description": "Short note title."],
                  "content": ["type": "string", "description": "The note body (markdown)."]],
                 required: ["title", "content"]),
            tool("current_datetime", "Get the current local date and time. Use this whenever recency matters (e.g. 'recent', dates, scheduling, or before a time-sensitive web_search).", [:]),
            tool("calculate", "Evaluate an arithmetic EXPRESSION exactly (+ - * / % ^ and parentheses). Use this for any math instead of computing it yourself.",
                 ["expression": ["type": "string", "description": "e.g. (3+4)*2^3 - 10%3"]], required: ["expression"]),
            tool("unit_convert", "Convert a value between units of LENGTH (m, km, cm, mm, mi, yd, ft, in), MASS (g, kg, mg, t, lb, oz), or TEMPERATURE (C, F, K).",
                 ["value": ["type": "number", "description": "The numeric value to convert."],
                  "from": ["type": "string", "description": "Source unit, e.g. 'km' or 'celsius'."],
                  "to": ["type": "string", "description": "Target unit, e.g. 'mi' or 'F'."]],
                 required: ["value", "from", "to"]),
            tool("translate", "Translate text into another language. Use when the user asks to translate something.",
                 ["text": ["type": "string", "description": "The text to translate."],
                  "to": ["type": "string", "description": "Target language, e.g. 'English', '中文', 'Spanish'."]],
                 required: ["text", "to"]),
            tool("translate_item", "Translate a whole FILE's contents into another language (by title).",
                 ["item": item,
                  "to": ["type": "string", "description": "Target language, e.g. 'English', '中文'."]],
                 required: ["item", "to"]),
            tool("compare_items", "Fetch TWO files so you can compare/contrast them. Returns both as numbered sources.",
                 ["item_a": ["type": "string", "description": "Title of the first file."],
                  "item_b": ["type": "string", "description": "Title of the second file."]],
                 required: ["item_a", "item_b"]),
            tool("diff_items", "Compute a line-level DIFF/changelog between two files (e.g. two versions of a doc) — shows exactly which lines were added/removed. Use for 'what changed between X and Y'.",
                 ["item_a": ["type": "string", "description": "Title of the OLD/first file."],
                  "item_b": ["type": "string", "description": "Title of the NEW/second file."]],
                 required: ["item_a", "item_b"]),
            tool("list_recent_artifacts", "List deliverables you've already built (so you can reference or extend them).",
                 ["limit": ["type": "integer", "description": "How many to list (default 8)."]]),
            tool("read_artifact", "Read the main file of a previously-built artifact (by title) so you can revise or build on it.",
                 ["name": ["type": "string", "description": "Title (or part of it) of a past artifact."]], required: ["name"]),
            tool("export_artifact", "Export/share a built artifact as a .zip on the Desktop (so the user can send or archive it). Use when the user asks to share, export, send, or save-out a deliverable.",
                 ["name": ["type": "string", "description": "Title (or part of it) of the artifact to export."]], required: ["name"]),
            tool("open_artifact", "Open a previously-built artifact in its default app (e.g. the HTML in a browser). Use when the user asks to open/show/view a deliverable.",
                 ["name": ["type": "string", "description": "Title (or part of it) of the artifact to open."]], required: ["name"]),
            tool("add_reminder", "Set a deferred task / reminder that persists (a TODO the Ask tab can act on later). Use when the user says 'remind me to…', 'follow up on…', or you defer work for later.",
                 ["title": ["type": "string", "description": "What to be reminded of / the task."],
                  "due": ["type": "string", "description": "Optional human-readable when ('tomorrow', 'Fri', '2026-07-01')."]],
                 required: ["title"]),
            tool("pin_fact", "PIN a fact to long-term memory so you ALWAYS remember it across every conversation (it's injected into context and never compacted away) — e.g. the user's name, preferences, or an ongoing project detail.",
                 ["fact": ["type": "string", "description": "The fact to remember permanently."]], required: ["fact"]),
            tool("list_pinned_facts", "List the facts pinned to long-term memory.", [:]),
            tool("unpin_fact", "Remove a fact from long-term memory (by its text or part of it).",
                 ["fact": ["type": "string", "description": "The pinned fact (or part) to remove."]], required: ["fact"]),
            tool("list_reminders", "List the user's open (and recently completed) reminders / deferred tasks.", [:]),
            tool("due_reminders", "List open reminders that are DUE SOON or OVERDUE — those whose due date falls within the next N days — earliest first. Use for 'what's due', 'what's coming up', 'anything overdue'.",
                 ["days": ["type": "integer", "description": "Look-ahead window in days (default 7). Overdue items always included."]]),
            tool("complete_reminder", "Mark a reminder / deferred task as done (by its title or part of it).",
                 ["reminder": ["type": "string", "description": "Title (or part) of the reminder to complete."]],
                 required: ["reminder"]),
        ]
    }

    /// Result of the tool-calling phase: the full conversation (system + history
    /// + tool results), accumulated citations, and how many searches ran.
    struct ToolPhase { var convo: [[String: Any]]; var citations: [Citation]; var searches: Int; var finish: FinishReason = .natural }

    /// Run search rounds until the model stops requesting tools (or rounds run
    /// out). Stops BEFORE the model writes its prose answer, so the caller can
    /// generate that final answer streamed or non-streamed as it likes.
    func runToolRounds(query: String, history: [ChatMessage], threadID: String? = nil,
                               onStatus: @Sendable @escaping (String) -> Void,
                               onPlan: @Sendable @escaping ([String]) -> Void = { _ in },
                               onPlanStep: @Sendable @escaping (Int) -> Void = { _ in }) async throws -> ToolPhase {
        // Long-context management: keep the whole thread until it's big, then compact
        // the oldest turns into one summary (DeepSeek's window is large + cheap).
        let history = await compactHistory(history, threadID: threadID, onStatus: onStatus)
        var convo: [[String: Any]] = [["role": "system", "content": Self.systemPrompt]]
        // Long-term memory: pinned facts are ALWAYS in context, never compacted away.
        if let facts = try? await store.allPinnedFacts(), !facts.isEmpty {
            let block = facts.map { "- \($0.fact)" }.joined(separator: "\n")
            convo.append(["role": "system",
                          "content": "PINNED FACTS the user wants you to always remember:\n\(block)"])
        }
        for m in history where m.role == .user || m.role == .assistant || m.role == .system {
            let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { convo.append(["role": m.role.rawValue, "content": t]) }
        }
        convo.append(["role": "user", "content": query])

        var citations: [Citation] = []
        var searches = 0
        var didMutate = false

        // Guarantee the user's OWN query is searched up-front FOR QUESTIONS — the
        // model sometimes rephrases (esp. across languages) into queries that miss an
        // exact name, then says "not found". But for ACTION requests ("delete the X
        // label", "组织标签"), seeding a knowledge search wrongly frames it as Q&A and
        // suppresses the action — so skip the seed and let the model call the tool.
        let isAction = Self.looksLikeAction(query)
        let seedHits = isAction ? [] : ((try? await store.search(vector: embedder.embed(query), queryText: query,
                                                                 k: topK, keywordWeight: keywordWeight)) ?? [])
        if !seedHits.isEmpty {
            onStatus("Searching: \(query)")
            searches += 1
            let (seedText, seedCites) = render(seedHits, startingAt: citations.count)
            citations.append(contentsOf: seedCites)
            let seedArgs = (try? JSONSerialization.data(withJSONObject: ["query": query]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            convo.append([
                "role": "assistant", "content": "",
                "tool_calls": [["id": "seed-0", "type": "function",
                                "function": ["name": "search_knowledge", "arguments": seedArgs]]]
            ])
            convo.append(["role": "tool", "tool_call_id": "seed-0", "content": seedText])
        }

        // PLAN phase: for a complex/multi-step goal, decompose it first and give the
        // agent a bigger round budget so it can run the whole thing to completion.
        var rounds = maxRounds
        var plan: [String] = []
        if Self.isComplexGoal(query) {
            onStatus("Planning…")
            plan = await makePlan(goal: query)
            if !plan.isEmpty {
                rounds = max(maxRounds, min(plan.count + 3, 10))
                onPlan(plan)
                let planText = plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                convo.append(["role": "system",
                              "content": "PLAN for this task — work through it, calling the right tool for each step, then summarise what you did:\n\(planText)"])
            }
        }

        // Per-step completion: the model works the ordered plan top-down, so each
        // tool-call round advances roughly one step — a live, honest pointer. The
        // final state is corrected by a cheap classification pass after the loop.
        var toolRounds = 0
        // Loop-guard (Claude Code/Codex best practice): never run the SAME tool with
        // the SAME args twice in a turn — return the prior result and nudge the model
        // to do something different or answer. Stops wasted rounds + tool ping-pong.
        var executed: [String: String] = [:]
        // No-progress cap: if a whole round does nothing new (no fresh calls, no new
        // citations, no mutation) twice running, force an answer instead of wandering.
        var stalls = 0
        // Why the tool loop ended — surfaced to the activity trace so the user knows
        // whether the agent finished, gave up on a dead-end, or hit its step budget.
        var finish: FinishReason = .roundLimit
        for _ in 0..<rounds {
            // The model call for the ACT loop now flows through the Fathom
            // SDK's LLMClient — one place owns the wire format, and tests inject a mock.
            let completion = try await llm.complete(
                messages: AgentLLMClient.messages(from: convo), tools: Self.tools())
            guard completion.wantsTools else {
                finish = .natural
                break   // model is ready to answer — stop here, discard any draft content
            }
            let calls = completion.toolCalls
            convo.append([
                "role": "assistant", "content": completion.content ?? "",
                "tool_calls": calls.map { [
                    "id": $0.id, "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments]
                ] }
            ])
            var freshThisRound = 0, newCitesThisRound = 0, mutatedThisRound = false
            for call in calls {
                searches += 1
                let sig = Self.callSignature(name: call.name, args: call.arguments)
                if let prior = executed[sig] {
                    convo.append(["role": "tool", "tool_call_id": call.id,
                                  "content": "(Already called \(call.name) with these exact arguments this turn. Its result was:\n\(prior)\nDon't repeat it — use that result, try DIFFERENT arguments or another tool, or answer now.)"])
                    continue
                }
                freshThisRound += 1
                if Self.mutationTools.contains(call.name) { didMutate = true; mutatedThisRound = true }
                let (rawResult, newCites) = await handleTool(
                    name: call.name, args: call.arguments,
                    fallbackQuery: query, citationOffset: citations.count, onStatus: onStatus)
                // Bound the model-facing result so one huge output (a long web page, a big
                // file dump) can't blow up context/cost. Citations were already collected
                // from the full result above, so clamping the text loses no sources.
                let resultText = Self.clampToolResult(rawResult)
                executed[sig] = resultText
                newCitesThisRound += newCites.count
                citations.append(contentsOf: newCites)
                convo.append(["role": "tool", "tool_call_id": call.id, "content": resultText])
            }
            if !plan.isEmpty {
                toolRounds += 1
                onPlanStep(min(toolRounds, plan.count))
            }
            if Self.isStall(freshCalls: freshThisRound, newCitations: newCitesThisRound, didMutate: mutatedThisRound) {
                stalls += 1
                if stalls >= 2 {
                    convo.append(["role": "system",
                                  "content": "Two rounds in a row added nothing new. Stop calling tools and answer now with the evidence you already have; be honest about any gaps."])
                    finish = .noProgress
                    break
                }
            } else { stalls = 0 }
        }
        // Tell the user (via the trace) when the agent stopped for a non-obvious
        // reason — a dead-end or the step budget — not when it finished cleanly.
        if let note = Self.finishTrace(finish) { onStatus(note) }

        // Correct the live estimate with one cheap pass: how many plan steps did the
        // transcript actually complete? Keeps the checklist honest (the model may do
        // two steps in one round, or revisit one) without an LLM call per round.
        if !plan.isEmpty {
            let done = await completedPlanSteps(plan: plan, convo: convo)
            onPlanStep(done)
            // Long-running behaviour: if the agent ran out of rounds with steps left,
            // it autonomously records a follow-up so the unfinished work isn't lost —
            // then tells the user, rather than silently dropping it.
            if let title = Self.deferredReminder(goal: query, plan: plan, completed: done) {
                reminders.add(title: title)
                onStatus("Saved a follow-up: \(title)")
                convo.append(["role": "system",
                              "content": "You did not finish every planned step. A follow-up reminder was saved: \"\(title)\". Briefly tell the user you saved a reminder for the remaining work so it can be continued later."])
            }
        }

        // VERIFY phase: a reviewer checks the evidence before we answer. It can ask
        // for one more targeted search (orchestration) or flag that the answer must
        // hedge. Cheap insurance against "not found" / ungrounded answers. Skipped
        // after a MUTATION — actions just need confirming, not evidence-checking.
        if critic, !didMutate, let action = try? await runCritic(convo: convo) {
            switch action {
            case .search(let q):
                onStatus("Verifying — searching: \(q)")
                searches += 1
                let hits = (try? await store.search(vector: embedder.embed(q), queryText: q,
                                                    k: topK, keywordWeight: keywordWeight)) ?? []
                let (text, cites) = render(hits, startingAt: citations.count)
                citations.append(contentsOf: cites)
                let a = (try? JSONSerialization.data(withJSONObject: ["query": q]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                convo.append(["role": "assistant", "content": "",
                              "tool_calls": [["id": "critic-0", "type": "function",
                                              "function": ["name": "search_knowledge", "arguments": a]]]])
                convo.append(["role": "tool", "tool_call_id": "critic-0", "content": text])
            case .note(let n):
                convo.append(["role": "system",
                              "content": "Reviewer: \(n) Be honest about what the sources do and don't support; do not invent."])
            case .ok:
                break
            }
        }

        onStatus("")
        return ToolPhase(convo: convo, citations: citations, searches: searches, finish: finish)
    }

    /// Apply the long-context policy: under budget ⇒ send the whole thread; over ⇒
    /// keep the recent turns verbatim and replace the oldest with a summary. The
    /// summary is persisted per-thread in SQLite and extended INCREMENTALLY — each
    /// turn only folds in the few newly-aged-out messages, never re-summarizing the
    /// whole prefix. Leverages DeepSeek's large, inexpensive context window.
    func compactHistory(_ history: [ChatMessage], threadID: String? = nil,
                        onStatus: @Sendable @escaping (String) -> Void = { _ in }) async -> [ChatMessage] {
        let plan = ContextManager.plan(history, budget: contextBudget)
        guard plan.compactUpTo > 0 else { return history }
        let recent = Array(history[plan.keepFrom...])

        // Reuse a cached summary covering [0..<cached.boundary]; only summarize the
        // gap [cached.boundary..<compactUpTo] this turn.
        var prior = ""
        var from = 0
        if let tid = threadID, let cached = try? await store.loadThreadSummary(threadID: tid),
           cached.boundary <= plan.compactUpTo {
            prior = cached.summary
            from = cached.boundary
        }
        let newlyAged = from < plan.compactUpTo ? Array(history[from..<plan.compactUpTo]) : []
        if newlyAged.isEmpty { return ContextManager.assemble(recent: recent, summary: prior) }

        onStatus("Compacting earlier conversation…")
        let summary = await summarizeTurns(prior: prior, msgs: newlyAged)
        if let tid = threadID {
            try? await store.saveThreadSummary(threadID: tid, boundary: plan.compactUpTo, summary: summary)
        }
        return ContextManager.assemble(recent: recent, summary: summary)
    }

    /// One cheap DeepSeek call that folds `msgs` into `prior` (the running summary),
    /// preserving names, decisions, facts, and open threads. Falls back to a
    /// truncated transcript when the call fails.
    private func summarizeTurns(prior: String, msgs: [ChatMessage]) async -> String {
        let transcript = msgs.map { "\($0.role.rawValue.uppercased()): \(String($0.content.prefix(2000)))" }
            .joined(separator: "\n")
        let sys = "Maintain a COMPACT running brief of a long conversation. Merge the new turns into the " +
            "existing summary, preserving names, key facts, decisions, and open questions. Reply with the " +
            "updated brief only (a few sentences), no preamble."
        let user = (prior.isEmpty ? "" : "EXISTING SUMMARY:\n\(prior)\n\n") + "NEW TURNS:\n\(transcript)"
        let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                   "messages": [["role": "system", "content": sys],
                                                ["role": "user", "content": user]],
                                   "temperature": 0.2, "tool_choice": "none"]
        guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
              let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = resp.choices.first?.message.content, !text.isEmpty else {
            return String(((prior.isEmpty ? "" : prior + "\n") + transcript).prefix(1500))
        }
        return text
    }

    /// PLAN phase — ask the model to decompose a complex goal into ordered steps.
    private func makePlan(goal: String) async -> [String] {
        let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                   "messages": [["role": "system", "content": Self.plannerPrompt],
                                                ["role": "user", "content": goal]],
                                   "temperature": 0, "tool_choice": "none"]
        guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
              let resp = try? JSONDecoder().decode(ChatResponse.self, from: data) else { return [] }
        return Self.parsePlan(resp.choices.first?.message.content ?? "")
    }

    /// How many of the ordered plan steps the transcript actually completed.
    /// One cheap non-tool call returning a single integer; on any failure we fall
    /// back to "all but the last" so the checklist still reads as near-done.
    private func completedPlanSteps(plan: [String], convo: [[String: Any]]) async -> Int {
        let planText = plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        // Summarise the tool activity (names + the model's own narration), not raw results.
        var activity: [String] = []
        for m in convo {
            if let calls = m["tool_calls"] as? [[String: Any]] {
                for c in calls { if let f = c["function"] as? [String: Any], let n = f["name"] as? String { activity.append("called \(n)") } }
            }
            if (m["role"] as? String) == "assistant", let t = m["content"] as? String, !t.isEmpty { activity.append(String(t.prefix(200))) }
        }
        let prompt = "PLAN:\n\(planText)\n\nWHAT THE AGENT DID:\n\(activity.suffix(30).joined(separator: "\n"))\n\nHow many of the \(plan.count) plan steps are fully completed? Reply with ONE integer from 0 to \(plan.count) and nothing else."
        let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                   "messages": [["role": "user", "content": prompt]],
                                   "temperature": 0, "tool_choice": "none"]
        guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
              let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let n = Self.parseStepCount(resp.choices.first?.message.content ?? "", max: plan.count)
        else { return max(0, plan.count - 1) }
        return n
    }

    /// Parse a strict ISO day (YYYY-MM-DD) at the start of local day; nil otherwise.
    static func parseISODate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// The cutoff for "recent changes": an explicit `since` date wins; otherwise
    /// `now` minus a day window (default 7, min 1). Pure → unit-testable.
    static func changeThreshold(days: Int?, since: String?, now: Date) -> Date {
        if let d = parseISODate(since) { return d }
        let window = Swift.max(1, days ?? 7)
        return now.addingTimeInterval(-Double(window) * 86_400)
    }

    /// A one-call health report of the knowledge base: coverage, untagged count,
    /// near-duplicate labels, plus concrete cleanup recommendations. Pure → testable.
    static func libraryHealthReport(total: Int, labelled: Int, untagged: Int,
                                    nearDupClusters: [[String]]) -> String {
        guard total > 0 else { return "Your library is empty — ingest some files to begin." }
        let cov = TagStats.coverage(labelled: labelled, total: total)
        var lines = ["Library health:",
                     "• \(cov.text).",
                     "• \(untagged) untagged file\(untagged == 1 ? "" : "s")."]
        if nearDupClusters.isEmpty {
            lines.append("• No near-duplicate labels.")
        } else {
            let sample = nearDupClusters.prefix(3).map { $0.joined(separator: "/") }.joined(separator: ", ")
            lines.append("• \(nearDupClusters.count) near-duplicate label group(s): \(sample).")
        }
        var recs: [String] = []
        if cov.pct < 70, untagged > 0 { recs.append("run auto_label_untagged to raise coverage") }
        if !nearDupClusters.isEmpty { recs.append("merge_tags to consolidate duplicate labels") }
        recs.append(recs.isEmpty ? "looking healthy — nothing urgent" : "")
        lines.append("Recommended: \(recs.filter { !$0.isEmpty }.joined(separator: "; ")).")
        return lines.joined(separator: "\n")
    }

    /// Propose labels for a file: prefer REUSING existing library labels that a
    /// salient term matches (avoids tag sprawl), then fill with fresh top keywords.
    /// Skips labels the item already has. Pure → unit-testable.
    static func proposeLabels(keywords: [String], existingTags: [String],
                              itemTags: [String], limit: Int = 5) -> [String] {
        let have = Set(itemTags.map { $0.lowercased() })
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let k = s.lowercased()
            guard !k.isEmpty, !have.contains(k), seen.insert(k).inserted, out.count < limit else { return }
            out.append(s)
        }
        let kws = keywords.map { $0.lowercased() }
        // 1) Existing library labels a keyword matches (substring either direction).
        for tag in existingTags {
            let t = tag.lowercased()
            if kws.contains(where: { $0 == t || $0.contains(t) || t.contains($0) }) { add(tag) }
        }
        // 2) Fresh top keywords as new labels.
        for kw in keywords { add(kw) }
        return Array(out.prefix(limit))
    }

    /// System prompt for the translate tool. Pure → testable.
    /// The translation system prompt — single-sourced in Fathom so the wording stays in
    /// one place. The translate / translate_item handlers still call DeepSeek directly.
    static func translatePrompt(to language: String) -> String {
        Fathom.Translation.systemPrompt(to: language)
    }

    /// Human-readable byte size: "512 B", "1.5 KB", "3.2 MB". Pure → testable.
    static func humanBytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(Swift.max(0, n)); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.1f %@", v, units[i])
    }

    /// Map a free-text kind word (with aliases) to an ItemKind, or nil. Pure/testable.
    static func matchKind(_ raw: String) -> ItemKind? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "pdf", "pdfs": return .pdf
        case "image", "images", "img", "photo", "photos", "picture", "pictures": return .image
        case "markdown", "md": return .markdown
        case "text", "txt", "plain": return .text
        case "code", "source", "script": return .code
        case "html", "htm": return .html
        case "webpage", "web", "url", "website", "bookmark", "bookmarks": return .webpage
        case "email", "emails", "mail": return .email
        case "word", "doc", "docx", "worddoc", "document", "documents": return .wordDoc
        case "richtext", "rtf": return .richtext
        case "data", "csv", "json", "spreadsheet": return .data
        default:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return ItemKind(rawValue: trimmed) ?? ItemKind(rawValue: trimmed.lowercased())
        }
    }

    /// Group file titles by identical content hash; only sets of ≥2 (true duplicates),
    /// largest first then alphabetical. Empty hashes are ignored. Pure → testable.
    static func duplicateGroups(_ items: [(title: String, hash: String)]) -> [[String]] {
        var byHash: [String: [String]] = [:]
        for it in items where !it.hash.isEmpty { byHash[it.hash, default: []].append(it.title) }
        return byHash.values.filter { $0.count >= 2 }.map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.first ?? "") < ($1.first ?? "") }
    }

    /// Normalize a filename so versioned / copied variants collapse to the same key:
    /// drop the extension, strip version & copy markers ("(1)", "copy", "final", "draft",
    /// "v2", a trailing standalone number), fold non-alphanumerics to single spaces, and
    /// lowercase. e.g. "Report Final v2.pdf", "report (1).pdf", "Report copy.docx" → "report".
    /// Pure → unit-testable.
    static func normalizedTitleKey(_ title: String) -> String {
        var s = title.lowercased()
        if let dot = s.lastIndex(of: "."), dot != s.startIndex {   // drop a real extension
            let ext = s[s.index(after: dot)...]
            if ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { s = String(s[..<dot]) }
        }
        s = s.replacingOccurrences(of: #"\(\s*\d+\s*\)"#, with: " ", options: .regularExpression) // (1)
        s = s.replacingOccurrences(of: #"\bv\d+\b"#, with: " ", options: .regularExpression)        // v2
        s = s.replacingOccurrences(of: #"\b(copy|final|draft|latest|new|old)\b"#, with: " ",
                                    options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)       // punctuation→space
        s = s.replacingOccurrences(of: #"\s+\d+\s*$"#, with: " ", options: .regularExpression)        // trailing number
        return s.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Group titles whose normalized key matches — near-duplicate filenames (versioned or
    /// copied), as opposed to byte-identical content. Only groups with ≥2 distinct titles
    /// and a non-empty key are returned, largest first then alphabetical. Pure → testable.
    static func similarTitleGroups(_ titles: [String]) -> [[String]] {
        var byKey: [String: [String]] = [:]
        var seenPerKey: [String: Set<String>] = [:]
        for t in titles {
            let key = normalizedTitleKey(t)
            guard !key.isEmpty else { continue }
            if seenPerKey[key, default: []].insert(t.lowercased()).inserted { byKey[key, default: []].append(t) }
        }
        return byKey.values.filter { $0.count >= 2 }.map { $0.sorted() }
            .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.first ?? "") < ($1.first ?? "") }
    }

    /// The id of the pinned fact matching `ref` (exact text, then substring), or nil.
    static func pinnedFactMatch(_ ref: String, in facts: [(id: String, fact: String)]) -> String? {
        let key = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let m = facts.first(where: { $0.fact.lowercased() == key }) { return m.id }
        return facts.first(where: { $0.fact.lowercased().contains(key) })?.id
    }

    /// Whether the library's top search score is strong enough to be treated as an
    /// authoritative local definition (else define_term falls back to the web). The
    /// default bar (0.3) clears genuine matches but not incidental low-cosine hits.
    static func kbClears(topScore: Float?, min: Float = 0.3) -> Bool {
        (topScore ?? 0) >= min
    }

    /// Items changed (created or modified) at/after `cutoff`, newest first. Shared by
    /// the recent_changes tool and the Insights "changed this week" panel.
    static func changedSince(_ items: [KnowledgeItem], _ cutoff: Date) -> [KnowledgeItem] {
        items.filter { Swift.max($0.modifiedAt, $0.createdAt) >= cutoff }
            .sorted { Swift.max($0.modifiedAt, $0.createdAt) > Swift.max($1.modifiedAt, $1.createdAt) }
    }

    /// Items whose chosen date falls in the inclusive `[start, end]` window, newest
    /// first. `useModified` picks the modified date (else created); an open-ended bound
    /// (nil) means "no limit on that side". `end` is taken as the END of that day so a
    /// same-day `start == end` range still includes items stamped later that day. Pure →
    /// unit-testable; backs the `find_by_date` tool.
    static func inDateRange(_ items: [KnowledgeItem], start: Date?, end: Date?,
                            useModified: Bool) -> [KnowledgeItem] {
        let endExclusive = end.map { $0.addingTimeInterval(86_400) }   // include the whole end day
        func when(_ i: KnowledgeItem) -> Date { useModified ? i.modifiedAt : i.createdAt }
        return items.filter { i in
            let d = when(i)
            if let s = start, d < s { return false }
            if let e = endExclusive, d >= e { return false }
            return true
        }.sorted { when($0) > when($1) }
    }

    /// Summarize per-day file-activity buckets (oldest→newest, newest = last index = today)
    /// into a readable trend: total changes, the busiest day, and the last-7-day total.
    /// Pure → unit-testable.
    static func activitySummary(_ buckets: [Int]) -> String {
        let total = buckets.reduce(0, +)
        guard total > 0, !buckets.isEmpty else { return "No file activity in this window." }
        let days = buckets.count
        var peak = 0
        for (i, v) in buckets.enumerated() where v > buckets[peak] { peak = i }
        let peakAgo = days - 1 - peak
        func ago(_ d: Int) -> String { d == 0 ? "today" : (d == 1 ? "yesterday" : "\(d) days ago") }
        let last7 = buckets.suffix(7).reduce(0, +)
        return "\(total) file change\(total == 1 ? "" : "s") over \(days) day\(days == 1 ? "" : "s"). " +
               "Busiest: \(buckets[peak]) on \(ago(peakAgo)). Last 7 days: \(last7)."
    }

    /// Resolve a saved-search reference to one entry: exact name (case-insensitive) wins,
    /// else a unique substring match. Returns nil if nothing or several match ambiguously.
    /// Pure → unit-testable.
    static func matchSavedSearch(_ ref: String, in searches: [SavedSearch]) -> SavedSearch? {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !r.isEmpty else { return nil }
        if let exact = searches.first(where: { $0.name.lowercased() == r }) { return exact }
        let subs = searches.filter { $0.name.lowercased().contains(r) }
        return subs.count == 1 ? subs.first : nil
    }

    /// Compose an autonomous "catch me up" briefing from the library's signals — recent
    /// changes, due/overdue reminders, and an untagged-tidy nudge. Sections with nothing
    /// to report are omitted (the library line always shows). Pure → unit-testable.
    static func briefing(totalItems: Int, windowDays: Int, changedRecently: [String],
                         dueReminders: [String], untagged: Int) -> String {
        guard totalItems > 0 else { return "Your library is empty — ingest some files to begin." }
        func sample(_ xs: [String], _ n: Int = 5) -> String {
            let shown = xs.prefix(n).joined(separator: ", ")
            return xs.count > n ? "\(shown), +\(xs.count - n) more" : shown
        }
        var lines = ["Here's your catch-up (last \(windowDays) day\(windowDays == 1 ? "" : "s")):",
                     "• Library: \(totalItems) item\(totalItems == 1 ? "" : "s")."]
        if changedRecently.isEmpty {
            lines.append("• No files changed in this window.")
        } else {
            lines.append("• Changed recently: \(changedRecently.count) — \(sample(changedRecently)).")
        }
        if !dueReminders.isEmpty {
            lines.append("• Due soon / overdue: \(dueReminders.count) — \(sample(dueReminders)).")
        }
        if untagged > 0 {
            lines.append("• \(untagged) untagged file\(untagged == 1 ? "" : "s") — run auto_label_untagged to tidy up.")
        }
        return lines.joined(separator: "\n")
    }

    /// Aggregate per-item language codes into a distribution sorted by count (desc),
    /// ties broken by code (asc). Empty codes are ignored. Pure → unit-testable; backs
    /// the `library_languages` tool.
    static func languageDistribution(_ codes: [String]) -> [(language: String, count: Int)] {
        var counts: [String: Int] = [:]
        for c in codes where !c.isEmpty { counts[c, default: 0] += 1 }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (language: $0.key, count: $0.value) }
    }

    /// Format a date as a YYYY-MM-DD day string (for change listings).
    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// A round made NO progress when it ran no fresh (non-repeat) calls, surfaced no
    /// new citations, and changed nothing. Two such rounds running ⇒ force an answer.
    static func isStall(freshCalls: Int, newCitations: Int, didMutate: Bool) -> Bool {
        freshCalls == 0 && newCitations == 0 && !didMutate
    }

    /// Parse a comma- (or newline-) separated list of item references into a clean,
    /// de-duplicated list, order preserved (case-insensitive dedupe, first spelling kept).
    /// Backs `batch_tag`. Pure → unit-testable.
    static func parseItemList(_ raw: String) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out
    }

    /// Autonomous label suggestion via a COLLABORATIVE signal: propose tags for an item
    /// from the labels its nearest neighbors carry, excluding ones the item already has.
    /// `neighborTags` is ordered most-similar-first; each neighbor contributes its tags
    /// with a rank-decayed weight (1/(rank+1)) so closer neighbors count more. The first
    /// spelling seen for a tag (case-insensitive) is the one returned. Sorted by score
    /// desc, ties by name asc. Distinct from `proposeLabels` (which uses the item's OWN
    /// keywords). Pure → unit-testable.
    static func tagsFromNeighbors(existing: Set<String>, neighborTags: [[String]],
                                  limit: Int = 5) -> [String] {
        let have = Set(existing.map { $0.lowercased() })
        var score: [String: Double] = [:]      // key: lowercased tag
        var display: [String: String] = [:]    // key → first-seen spelling
        var firstIndex: [String: Int] = [:]     // key → first appearance order (stable tiebreak)
        var order = 0
        for (rank, tags) in neighborTags.enumerated() {
            let weight = 1.0 / Double(rank + 1)
            for tag in tags {
                let k = tag.lowercased()
                guard !k.isEmpty, !have.contains(k) else { continue }
                score[k, default: 0] += weight
                if display[k] == nil { display[k] = tag; firstIndex[k] = order; order += 1 }
            }
        }
        let ranked = score.keys.sorted { a, b in
            if score[a]! != score[b]! { return score[a]! > score[b]! }   // higher score first
            return a < b                                                  // ties: name asc
        }
        return ranked.prefix(limit).compactMap { display[$0] }
    }

    /// Autonomous suggestion: from a source item's tags and its semantically-related
    /// candidates, surface the ones that share NO tag with the source — topically near
    /// but not yet linked, so the agent can offer to co-tag them. Candidate order (the
    /// caller's similarity ranking) is preserved. Tag matching is case-insensitive. An
    /// untagged candidate qualifies (it's a prime connection opportunity). Pure → testable.
    static func suggestedConnections(sourceTags: Set<String>,
                                     candidates: [(id: String, title: String, tags: Set<String>)])
        -> [(id: String, title: String, sharedNone: Bool)] {
        let src = Set(sourceTags.map { $0.lowercased() })
        return candidates.compactMap { c in
            let ctags = Set(c.tags.map { $0.lowercased() })
            return ctags.isDisjoint(with: src) ? (id: c.id, title: c.title, sharedNone: true) : nil
        }
    }

    /// Bound a single tool result fed back to the model, so one huge output (a long web
    /// page, a big file dump) can't blow up the agent's context window or cost — a Claude
    /// Code / Codex best practice. Keeps the head (where the answer usually is) and appends
    /// a clear truncation marker with the dropped character count, nudging the model to
    /// narrow its next step. Counted in Characters so multibyte text (CJK) is bounded too.
    /// Pure → unit-testable.
    static func clampToolResult(_ s: String, max: Int = 12_000) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max))
        let dropped = s.count - max
        return head + "\n\n…[truncated \(dropped) characters — result too large. " +
            "If you need more, use a narrower query/tool, get_item, or summarize_item.]"
    }

    /// A stable signature for a tool call so identical calls (even with reordered
    /// JSON keys) collapse to the same key — used to de-dup calls within a turn.
    static func callSignature(name: String, args: String) -> String {
        if let data = args.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let norm = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let s = String(data: norm, encoding: .utf8) {
            return name + ":" + s
        }
        return name + ":" + args.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frame several labelled files as numbered sources + citations for a cohesive
    /// summary. Pure (no store) → unit-testable.
    static func tagSummaryFraming(tag: String,
                                  sources: [(title: String, path: String, itemID: String, body: String)],
                                  citationOffset: Int) -> (String, [Citation]) {
        var text = ""
        var cites: [Citation] = []
        for (i, s) in sources.enumerated() {
            let n = citationOffset + i + 1
            text += "[\(n)] (\(s.title)) \(s.body)\n"
            cites.append(Citation(index: n, title: s.title, path: s.path,
                                  snippet: String(s.body.prefix(200)), itemID: s.itemID))
        }
        return ("Files labelled '\(tag)':\n\(text)\nWrite a cohesive summary of what these \(sources.count) file(s) cover, citing each point with its [n].", cites)
    }

    /// Frame one file's full text as a numbered source + citation with a summarize
    /// instruction. Pure (no store) so it's unit-testable; truncates to `maxChars`.
    static func itemSummaryFraming(title: String, path: String, itemID: String,
                                   fullText: String, citationOffset: Int, maxChars: Int = 8000) -> (String, [Citation]) {
        let n = citationOffset + 1
        let body = String(fullText.prefix(maxChars))
        let text = "[\(n)] (\(title)) \(body)\nWrite a concise, well-structured summary of this file — its key points and takeaways — citing [\(n)]."
        return (text, [Citation(index: n, title: title, path: path,
                                snippet: String(body.prefix(200)), itemID: itemID)])
    }

    /// Format multiple fetched web sources into a numbered corpus + citations the
    /// model can synthesize from. Pure (no network) so it's unit-testable.
    static func researchDigest(query: String,
                               sources: [(title: String, url: String, body: String)],
                               citationOffset: Int) -> (String, [Citation]) {
        var text = ""
        var cites: [Citation] = []
        for (i, s) in sources.enumerated() {
            let n = citationOffset + i + 1
            text += "[\(n)] (\(s.title)) \(s.url)\n\(s.body)\n\n"
            cites.append(Citation(index: n, title: s.title, path: s.url, snippet: String(s.body.prefix(200))))
        }
        let header = "Web research on '\(query)' — \(sources.count) source\(sources.count == 1 ? "" : "s") read:\n"
        return (header + text + "Synthesize a grounded answer to the question, citing each fact with its [n].", cites)
    }

    /// Apply a tag-merge to ONE item's labels: every `sources` label becomes
    /// `target`, order preserved, case-insensitive dedup. Returns the new label set
    /// only if it actually changed (so callers skip untouched items), else nil.
    static func mergedTags(_ tags: [String], from sources: Set<String>, into target: String) -> [String]? {
        let low = Set(sources.map { $0.lowercased() })
        guard tags.contains(where: { low.contains($0.lowercased()) }) else { return nil }
        var out: [String] = []
        var seen = Set<String>()
        func push(_ t: String) { if seen.insert(t.lowercased()).inserted { out.append(t) } }
        for t in tags { push(low.contains(t.lowercased()) ? target : t) }
        return out == tags ? nil : out
    }

    /// A human-readable digest of the knowledge base — totals, kind breakdown, top
    /// labels, untagged count, and the newest files. Pure (no store) for testing.
    static func librarySummary(items: [KnowledgeItem], topTags: [(String, Int)],
                               untagged: Int, chunks: Int, recent: Int = 5) -> String {
        guard !items.isEmpty else { return "The knowledge base is empty — nothing to summarize yet." }
        func plural(_ n: Int, _ s: String) -> String { "\(n) \(s)\(n == 1 ? "" : "s")" }
        var byKind: [String: Int] = [:]
        for it in items { byKind[it.kind.rawValue, default: 0] += 1 }
        let kinds = byKind.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        let tagText = topTags.isEmpty ? "none yet"
            : topTags.prefix(8).map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
        let newest = items
            .sorted { Swift.max($0.modifiedAt, $0.createdAt) > Swift.max($1.modifiedAt, $1.createdAt) }
            .prefix(recent).map(\.title).joined(separator: "; ")
        return """
        Library digest — \(plural(items.count, "item")), \(plural(chunks, "chunk")).
        By kind — \(kinds).
        Labels — \(tagText).
        Untagged — \(plural(untagged, "item")).
        Newest — \(newest).
        """
    }

    /// When a multi-step plan ends unfinished, the title of the follow-up reminder
    /// to save (the next undone step + a count of the rest), or nil when there's
    /// nothing worth deferring (single-step plan, or everything completed).
    static func deferredReminder(goal: String, plan: [String], completed: Int) -> String? {
        guard plan.count >= 2, completed >= 0, completed < plan.count else { return nil }
        let remaining = Array(plan.dropFirst(completed))
        guard let next = remaining.first else { return nil }
        let more = remaining.count > 1 ? " (+\(remaining.count - 1) more step\(remaining.count - 1 == 1 ? "" : "s"))" : ""
        return "Continue: \(next)\(more)"
    }

    /// First integer in `text`, clamped to 0…max. nil when none found.
    static func parseStepCount(_ text: String, max: Int) -> Int? {
        guard let r = text.range(of: #"\d+"#, options: .regularExpression),
              let v = Int(text[r]) else { return nil }
        return Swift.min(Swift.max(v, 0), max)
    }

    /// Reviewer pass — one non-tool call returning a single-line decision.
    private func runCritic(convo: [[String: Any]]) async throws -> CriticAction {
        var c = convo
        c.append(["role": "system", "content": Self.criticPrompt])
        let body: [String: Any] = ["model": deepSeek.config.deepSeekModel, "messages": c,
                                   "temperature": 0, "tool_choice": "none"]
        let data = try await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body))
        let resp = try JSONDecoder().decode(ChatResponse.self, from: data)
        return Self.parseCriticDecision(resp.choices.first?.message.content ?? "")
    }

    private func finalBody(_ convo: [[String: Any]], stream: Bool) -> [String: Any] {
        ["model": deepSeek.config.deepSeekModel, "messages": convo,
         "temperature": temperature, "tool_choice": "none", "stream": stream]
    }

    /// Non-streaming: run tool rounds, then generate the grounded answer.
    func answer(query: String,
                history: [ChatMessage], threadID: String? = nil,
                onStatus: @Sendable @escaping (String) -> Void = { _ in }) async throws -> Answer {
        let phase = try await runToolRounds(query: query, history: history, threadID: threadID, onStatus: onStatus)
        let data = try await deepSeek.rawChat(
            body: JSONSerialization.data(withJSONObject: finalBody(phase.convo, stream: false)))
        let resp = try JSONDecoder().decode(ChatResponse.self, from: data)
        return Answer(text: resp.choices.first?.message.content ?? "",
                      citations: phase.citations, searches: phase.searches)
    }

    /// Streaming: run tool rounds, surface citations, then stream the final answer
    /// token-by-token (`onCitations` fires once searching is done).
    func answerStream(query: String,
                      history: [ChatMessage], threadID: String? = nil,
                      onStatus: @Sendable @escaping (String) -> Void = { _ in },
                      onCitations: @Sendable @escaping ([Citation]) -> Void = { _ in },
                      onPlan: @Sendable @escaping ([String]) -> Void = { _ in },
                      onPlanStep: @Sendable @escaping (Int) -> Void = { _ in },
                      onFinishNote: @Sendable @escaping (String?) -> Void = { _ in })
        -> AsyncThrowingStream<StreamDelta, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let phase = try await runToolRounds(query: query, history: history, threadID: threadID,
                                                        onStatus: onStatus, onPlan: onPlan,
                                                        onPlanStep: onPlanStep)
                    onCitations(phase.citations)
                    onFinishNote(Self.finishTrace(phase.finish))
                    let body = try JSONSerialization.data(withJSONObject: finalBody(phase.convo, stream: true))
                    for try await token in deepSeek.rawStream(body: body) {
                        if Task.isCancelled { break }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Turn hits into a numbered tool-result string and matching citations.
    private func render(_ hits: [RetrievedChunk], startingAt offset: Int) -> (String, [Citation]) {
        guard !hits.isEmpty else { return ("No matching sources found.", []) }
        var text = ""
        var cites: [Citation] = []
        for (i, hit) in hits.enumerated() {
            let n = offset + i + 1
            let snippet = String(hit.chunk.text.prefix(600)).replacingOccurrences(of: "\n", with: " ")
            text += "[\(n)] (\(hit.item.title)) \(snippet)\n"
            cites.append(Citation(index: n, title: hit.item.title, path: hit.item.path,
                                  snippet: snippet, itemID: hit.item.id))
        }
        return (text, cites)
    }

    /// Dispatch one tool call to the knowledge store and return a result string
    /// (plus any citations, for search). Never throws — failures become a message
    /// the model can read and recover from.
    private func handleTool(name: String, args: String, fallbackQuery: String,
                            citationOffset: Int,
                            onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation]) {
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

        case "tag_stats":
            onStatus("Analyzing labels…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let total = (try? await store.itemCount()) ?? byItem.count
            let labelled = byItem.values.filter { !$0.isEmpty }.count
            let cov = TagStats.coverage(labelled: labelled, total: total)
            return (TagStats.summary(Array(byItem.values)) + "\nCoverage — \(cov.text).", [])

        case "library_health":
            onStatus("Checking library health…")
            let total = (try? await store.itemCount()) ?? 0
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let labelled = byItem.values.filter { !$0.isEmpty }.count
            let untagged = Swift.max(0, total - labelled)
            let tags = ((try? await store.allTags()) ?? []).map { ($0.tag, $0.count) }
            let clusters = TagCleanup.nearDuplicateClusters(tags)
            return (Self.libraryHealthReport(total: total, labelled: labelled,
                                             untagged: untagged, nearDupClusters: clusters), [])

        case "find_duplicates":
            onStatus("Scanning for duplicate files…")
            let items = (try? await store.allItems()) ?? []
            let groups = Self.duplicateGroups(items.map { (title: $0.title, hash: $0.contentHash) })
            guard !groups.isEmpty else { return ("No exact duplicate files found.", []) }
            let text = groups.prefix(20).map { "• \($0.joined(separator: " = "))" }.joined(separator: "\n")
            return ("\(groups.count) set(s) of identical files:\n\(text)", [])

        case "find_similar_titles":
            onStatus("Scanning for near-duplicate filenames…")
            let items = (try? await store.allItems()) ?? []
            let groups = Self.similarTitleGroups(items.map(\.title))
            guard !groups.isEmpty else { return ("No near-duplicate filenames found.", []) }
            let text = groups.prefix(20).map { "• \($0.joined(separator: " ~ "))" }.joined(separator: "\n")
            return ("\(groups.count) set(s) of similarly-named files (may be versions/copies):\n\(text)", [])

        case "library_themes":
            onStatus("Finding dominant topics…")
            let items = (try? await store.allItems()) ?? []
            let themes = KeywordExtractor.libraryThemes(docs: items.map { "\($0.title) \($0.summary)" })
            guard !themes.isEmpty else { return ("Not enough overlapping content to surface clear themes yet.", []) }
            return ("Top themes across \(items.count) file(s): "
                    + themes.map { "\($0.term) (\($0.count))" }.joined(separator: ", "), [])

        case "find_by_kind":
            guard let raw = arg("kind") else { return ("Missing 'kind'.", []) }
            guard let kind = Self.matchKind(raw) else {
                return ("Unknown file kind '\(raw)'. Try pdf, image, markdown, text, code, webpage, email, or word.", [])
            }
            onStatus("Finding \(kind.rawValue) files…")
            let matched = ((try? await store.allItems()) ?? []).filter { $0.kind == kind }
            return matched.isEmpty ? ("No \(kind.rawValue) files in the library.", [])
                : ("\(matched.count) \(kind.rawValue) file(s): " + matched.prefix(40).map(\.title).joined(separator: "; "), [])

        case "library_languages":
            onStatus("Detecting languages across the library…")
            let cap = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 300, 1), 1000)
            let items = ((try? await store.allItems()) ?? []).prefix(cap)
            guard !items.isEmpty else { return ("The knowledge base is empty.", []) }
            var codes: [String] = []
            for it in items {
                // Sample the first chunk's text — enough signal for language ID, cheap.
                let sample = ((try? await store.chunkTexts(forItem: it.id)) ?? []).first ?? ""
                if let r = LanguageDetector.detect(sample) { codes.append(r.dominant) }
            }
            let dist = Self.languageDistribution(codes)
            guard !dist.isEmpty else { return ("Couldn't detect languages (too little text in \(items.count) sampled file(s)).", []) }
            let total = dist.reduce(0) { $0 + $1.count }
            let parts = dist.map { d -> String in
                let pct = Int((Double(d.count) / Double(total) * 100).rounded())
                return "\(LanguageDetector.name(for: d.language)) \(d.count) (\(pct)%)"
            }
            return ("Languages across \(total) sampled file(s): " + parts.joined(separator: ", "), [])

        case "catch_me_up":
            onStatus("Putting together your briefing…")
            let days = Int(arg("days") ?? "") ?? 7
            let now = Date()
            let items = (try? await store.allItems()) ?? []
            let changed = Self.changedSince(items, Self.changeThreshold(days: days, since: nil, now: now)).map(\.title)
            let due = ReminderStore.dueSoon(reminders.all(), within: days, now: now).map(\.title)
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let untagged = items.filter { (byItem[$0.id] ?? []).isEmpty }.count
            return (Self.briefing(totalItems: items.count, windowDays: days,
                                  changedRecently: changed, dueReminders: due, untagged: untagged), [])

        case "library_stats":
            onStatus("Counting the knowledge base…")
            let items = (try? await store.allItems()) ?? []
            let chunks = (try? await store.chunkCount()) ?? 0
            var byKind: [String: Int] = [:]
            for it in items { byKind[it.kind.rawValue, default: 0] += 1 }
            let kinds = byKind.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return ("\(items.count) items, \(chunks) chunks. By kind — \(kinds).", [])

        case "most_cited":
            onStatus("Finding your most-referenced files…")
            let n = Swift.min(Swift.max(Int(arg("limit") ?? "") ?? 5, 1), 25)
            let top = (try? await store.mostCited(limit: n)) ?? []
            guard !top.isEmpty else { return ("No files have been cited yet — ask a question and I'll start tracking which sources you rely on.", []) }
            let list = top.map { "\($0.item.title) (\($0.count) citation\($0.count == 1 ? "" : "s"))" }.joined(separator: "; ")
            return ("Most-referenced files: \(list)", [])

        case "activity_trend":
            onStatus("Measuring activity…")
            let days = Swift.min(Swift.max(Int(arg("days") ?? "") ?? 30, 1), 90)
            let buckets = (try? await store.ingestActivity(days: days)) ?? []
            return ("Activity (last \(days) days): " + Self.activitySummary(buckets), [])

        case "summarize_library":
            onStatus("Summarizing your library…")
            let items = (try? await store.allItems()) ?? []
            let chunks = (try? await store.chunkCount()) ?? 0
            let tags = (try? await store.allTags()) ?? []
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let untagged = items.filter { (byItem[$0.id] ?? []).isEmpty }.count
            return (Self.librarySummary(items: items, topTags: tags.map { ($0.tag, $0.count) },
                                        untagged: untagged, chunks: chunks), [])

        case "find_by_tag":
            guard let tag = arg("tag") else { return ("Missing 'tag'.", []) }
            onStatus("Finding files labelled '\(tag)'…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let items = (try? await store.allItems()) ?? []
            let want = tag.lowercased()
            let matches = items.filter { (byItem[$0.id] ?? []).contains { $0.lowercased() == want } }
            return matches.isEmpty ? ("No files carry the label '\(tag)'.", [])
                : ("\(matches.count) file(s) labelled '\(tag)': " + matches.prefix(30).map(\.title).joined(separator: "; "), [])

        case "summarize_tag":
            guard let tag = arg("tag") else { return ("Missing 'tag'.", []) }
            onStatus("Summarizing '\(tag)'…")
            let byItem = (try? await store.tagsByItem()) ?? [:]
            let items = (try? await store.allItems()) ?? []
            let want = tag.lowercased()
            let matches = items.filter { (byItem[$0.id] ?? []).contains { $0.lowercased() == want } }
            guard !matches.isEmpty else { return ("No files carry the label '\(tag)' to summarize.", []) }
            var sources: [(title: String, path: String, itemID: String, body: String)] = []
            for it in matches.prefix(12) {
                let body = String(((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: " ").prefix(800))
                sources.append((it.title, it.path, it.id, body))
            }
            return Self.tagSummaryFraming(tag: tag, sources: sources, citationOffset: citationOffset)

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

        case "keyword_extract":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Extracting key terms from \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            return ("Top terms in '\(it.title)': \(KeywordExtractor.summary(full))", [])

        case "extract_links":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding links in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let links = LinkExtractor.extract(text)
            guard !links.isEmpty else { return ("No web links found in '\(it.title)'.", []) }
            return ("\(links.count) link(s) in '\(it.title)':\n" + links.map { "• \($0)" }.joined(separator: "\n"), [])

        case "extract_dates":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding dates in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let dates = DateExtractor.extract(text)
            guard !dates.isEmpty else { return ("No dates found in '\(it.title)'.", []) }
            return ("\(dates.count) date(s) in '\(it.title)': " + dates.joined(separator: "; "), [])

        case "timeline":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Building a timeline for \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let ordered = DateExtractor.chronological(text)
            guard !ordered.isEmpty else { return ("No dates to build a timeline from in '\(it.title)'.", []) }
            return ("Timeline of '\(it.title)' (earliest → latest):\n" +
                    ordered.map { "• \($0)" }.joined(separator: "\n"), [])

        case "extract_emails":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding emails in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let emails = EmailAddressExtractor.extract(text)
            guard !emails.isEmpty else { return ("No email addresses found in '\(it.title)'.", []) }
            return ("\(emails.count) email(s) in '\(it.title)': " + emails.joined(separator: ", "), [])

        case "extract_phone_numbers":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding phone numbers in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let phones = PhoneExtractor.extract(text)
            guard !phones.isEmpty else { return ("No phone numbers found in '\(it.title)'.", []) }
            return ("\(phones.count) phone number(s) in '\(it.title)': " + phones.joined(separator: ", "), [])

        case "extract_contacts":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Rounding up contacts in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let people = EntityExtractor.extract(text).filter { $0.kind == .person }.map(\.name)
            let emails = EmailAddressExtractor.extract(text)
            let phones = PhoneExtractor.extract(text)
            guard let rollup = ContactRollup.format(people: people, emails: emails, phones: phones) else {
                return ("No contacts (people, emails, or phone numbers) found in '\(it.title)'.", [])
            }
            return ("Contacts in '\(it.title)':\n" + rollup, [])

        case "extract_figures":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding amounts & percentages in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = FigureExtractor.summary(text) else {
                return ("No monetary amounts or percentages found in '\(it.title)'.", [])
            }
            return ("Figures in '\(it.title)':\n" + summary, [])

        case "extract_questions":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding questions in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let questions = QuestionExtractor.extract(text)
            guard !questions.isEmpty else { return ("No questions found in '\(it.title)'.", []) }
            return ("\(questions.count) question(s) in '\(it.title)':\n" + questions.map { "• \($0)" }.joined(separator: "\n"), [])

        case "extract_acronyms":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding acronyms in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = AcronymExtractor.summary(text) else {
                return ("No acronyms found in '\(it.title)'.", [])
            }
            return ("Acronyms in '\(it.title)': \(summary)", [])

        case "extract_code_blocks":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding code snippets in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = CodeBlockExtractor.summary(text) else {
                return ("No fenced code blocks found in '\(it.title)'.", [])
            }
            return ("Code in '\(it.title)':\n\(summary)", [])

        case "extract_action_items":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding action items in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let items = ActionItemExtractor.extract(text)
            guard !items.isEmpty else { return ("No action items found in '\(it.title)'.", []) }
            return ("\(items.count) action item(s) in '\(it.title)':\n" + items.map { "• \($0)" }.joined(separator: "\n"), [])

        case "entity_extract":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding people, orgs & places in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = EntityExtractor.summary(text) else {
                return ("No named entities (people, organizations, places) found in '\(it.title)'.", [])
            }
            return ("Entities in '\(it.title)':\n" + summary, [])

        case "sentiment":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Gauging the tone of \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = SentimentAnalyzer.summary(text) else {
                return ("Couldn't gauge sentiment for '\(it.title)' (no readable text).", [])
            }
            return ("Tone of '\(it.title)': " + summary, [])

        case "detect_language":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Detecting the language of \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = LanguageDetector.summary(text) else {
                return ("Couldn't detect a language for '\(it.title)' (too little text).", [])
            }
            return ("Language of '\(it.title)': " + summary, [])

        case "reading_time":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Measuring \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            return ("'\(it.title)' — \(ReadingTime.summary(text)).", [])

        case "readability":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Scoring the readability of \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = ReadabilityAnalyzer.summary(text) else {
                return ("Couldn't score '\(it.title)' (too short, or not English-oriented text — readability is English-based).", [])
            }
            return ("Readability of '\(it.title)': " + summary, [])

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

        case "create_artifact":
            guard let task = arg("task") else { return ("Missing 'task'.", []) }
            // DeepSeek-native by default (no CLI). If a CLI engine is chosen, try it,
            // then the other CLI, then DeepSeek as a guaranteed fallback.
            let order = Self.buildOrder(preferred: buildEngine,
                                        claudeAvailable: ClaudeCodeClient.isAvailable,
                                        codexAvailable: CodexCliClient.isAvailable)
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
            func mtimes() -> [String: Date] {
                var m: [String: Date] = [:]
                for f in filesNow() {
                    m[f] = (try? FileManager.default.attributesOfItem(atPath: dir + "/" + f))?[.modificationDate] as? Date
                }
                return m
            }
            let baseline = revisedTitle != nil ? mtimes() : [:]
            // Success: a fresh build produced files; a revision changed/added one.
            func produced() -> Bool {
                let now = mtimes()
                if revisedTitle == nil { return !now.isEmpty }
                for (f, m) in now where baseline[f] == nil || m > (baseline[f] ?? .distantPast) { return true }
                return false
            }
            let buildTask = revisedTitle != nil ? "REVISE the existing files here (read them first): \(task)" : task

            var used: String?
            for engine in order {
                onStatus("Building with \(engine.label): \(task)…")
                switch engine {
                case .deepseek:
                    // Native multi-file developer build (Claude Code-style). Falls back
                    // to a single self-contained HTML page if the manifest build yields nothing.
                    let built = await DeepSeekBuilder(deepSeek: deepSeek)
                        .build(task: buildTask, context: context, workdir: dir, onStatus: onStatus)
                    if built.isEmpty, let html = await deepSeekBuildHTML(task: buildTask, context: context) {
                        try? html.write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
                    }
                case .codex:
                    _ = await CodexCliClient.createArtifact(task: buildTask, context: context, workdir: dir)
                case .claude:
                    _ = await ClaudeCodeClient.createArtifact(task: buildTask, context: context, workdir: dir)
                }
                if produced() { used = engine.label; break }
                if order.count > 1 { onStatus("\(engine.label) produced nothing — trying the next build agent…") }
            }
            guard produced(), let used else {
                return ("Couldn't build it — every build agent failed (possibly all rate-limited). Try again later.", [])
            }
            // A revision invalidates the cached preview so the gallery re-renders it.
            if revisedTitle != nil { try? FileManager.default.removeItem(atPath: dir + "/.thumbnail.png") }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)]) }
            let files = filesNow()
            let verb = revisedTitle.map { "Revised '\($0)'" } ?? "Built \(files.count) file(s)"
            return ("\(verb) with \(used) — \(files.joined(separator: ", ")) — in \(dir). Revealed in Finder.", [])

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

        case "calculate":
            guard let expr = arg("expression")?.trimmingCharacters(in: .whitespacesAndNewlines), !expr.isEmpty
            else { return ("Missing 'expression'.", []) }
            guard let v = Calculator.eval(expr) else {
                return ("Couldn't evaluate '\(expr)' — check the expression (only + - * / % ^ and parentheses).", [])
            }
            return ("\(expr) = \(Calculator.format(v))", [])

        case "unit_convert":
            guard let vs = arg("value"), let v = Double(vs),
                  let from = arg("from"), let to = arg("to") else { return ("Missing 'value', 'from', or 'to'.", []) }
            guard let r = UnitConvert.convert(v, from: from, to: to) else {
                return ("Can't convert '\(from)' to '\(to)' — unknown units or different dimensions.", [])
            }
            return ("\(Calculator.format(v)) \(from) = \(Calculator.format(r)) \(to)", [])

        case "translate":
            guard let text = arg("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let to = arg("to")?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty
            else { return ("Missing 'text' or 'to'.", []) }
            onStatus("Translating to \(to)…")
            let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                       "messages": [["role": "system", "content": Self.translatePrompt(to: to)],
                                                    ["role": "user", "content": text]],
                                       "temperature": 0.2, "tool_choice": "none"]
            guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
                  let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let translated = resp.choices.first?.message.content, !translated.isEmpty else {
                return ("Couldn't translate that right now.", [])
            }
            return ("Translation (\(to)):\n\(translated)", [])

        case "translate_item":
            guard let ref = arg("item"),
                  let to = arg("to")?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty
            else { return ("Missing 'item' or 'to'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Translating \(it.title) to \(to)…")
            let text = String(((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n").prefix(6000))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("'\(it.title)' has no readable text to translate.", [])
            }
            let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                       "messages": [["role": "system", "content": Self.translatePrompt(to: to)],
                                                    ["role": "user", "content": text]],
                                       "temperature": 0.2, "tool_choice": "none"]
            guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
                  let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let translated = resp.choices.first?.message.content, !translated.isEmpty else {
                return ("Couldn't translate '\(it.title)' right now.", [])
            }
            return ("'\(it.title)' translated to \(to):\n\(translated)", [])

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

        case "pin_fact":
            guard let fact = arg("fact")?.trimmingCharacters(in: .whitespacesAndNewlines), !fact.isEmpty
            else { return ("Missing 'fact'.", []) }
            onStatus("Pinning to memory…")
            try? await store.addPinnedFact(fact)
            return ("Pinned to long-term memory — I'll always remember: “\(fact)”.", [])

        case "list_pinned_facts":
            onStatus("Reading long-term memory…")
            let facts = (try? await store.allPinnedFacts()) ?? []
            return facts.isEmpty ? ("Nothing pinned to long-term memory yet.", [])
                : ("Pinned facts:\n" + facts.map { "• \($0.fact)" }.joined(separator: "\n"), [])

        case "unpin_fact":
            guard let ref = arg("fact") else { return ("Missing 'fact'.", []) }
            onStatus("Updating long-term memory…")
            let facts = (try? await store.allPinnedFacts()) ?? []
            guard let id = Self.pinnedFactMatch(ref, in: facts) else {
                return facts.isEmpty ? ("No pinned facts to remove.", [])
                    : ("No pinned fact matches '\(ref)'. Pinned: \(facts.map(\.fact).joined(separator: "; ")).", [])
            }
            try? await store.removePinnedFact(id: id)
            return ("Unpinned that fact from long-term memory.", [])

        case "add_reminder":
            guard let title = arg("title") else { return ("Missing 'title'.", []) }
            onStatus("Setting a reminder: \(title)…")
            let r = reminders.add(title: title, due: arg("due"))
            let when = r.due.map { " (due \($0))" } ?? ""
            return ("Reminder set: “\(r.title)”\(when). I'll keep it in your task list.", [])

        case "list_reminders":
            onStatus("Reading your reminders…")
            let all = reminders.all()
            let open = all.filter { !$0.done }
            if all.isEmpty { return ("You have no reminders or deferred tasks.", []) }
            func line(_ r: Reminder) -> String {
                "\(r.done ? "✓" : "○") \(r.title)" + (r.due.map { " — due \($0)" } ?? "")
            }
            let openText = open.isEmpty ? "No open tasks." : open.map(line).joined(separator: "\n")
            let doneRecent = all.filter { $0.done }.prefix(3)
            let doneText = doneRecent.isEmpty ? "" : "\n\nRecently done:\n" + doneRecent.map(line).joined(separator: "\n")
            return ("Open tasks (\(open.count)):\n\(openText)\(doneText)", [])

        case "due_reminders":
            onStatus("Checking what's due…")
            let days = Int(arg("days") ?? "") ?? 7
            let now = Date()
            let due = ReminderStore.dueSoon(reminders.all(), within: days, now: now)
            guard !due.isEmpty else {
                return ("Nothing with a dated due in the next \(days) day(s). (Reminders with vague dues like 'tomorrow' aren't date-tracked.)", [])
            }
            func line(_ r: Reminder) -> String {
                let d = r.due.flatMap(DateExtractor.parse)
                let overdue = (d.map { $0 < now } ?? false) ? " ⚠️ OVERDUE" : ""
                return "○ \(r.title) — due \(r.due ?? "?")\(overdue)"
            }
            return ("\(due.count) reminder(s) due within \(days) day(s):\n" + due.map(line).joined(separator: "\n"), [])

        case "complete_reminder":
            guard let ref = arg("reminder") else { return ("Missing 'reminder'.", []) }
            onStatus("Completing reminder…")
            guard let r = reminders.complete(matching: ref) else {
                let open = reminders.all().filter { !$0.done }.map(\.title)
                return open.isEmpty ? ("No reminder matches '\(ref)' (your task list is empty).", [])
                    : ("No reminder matches '\(ref)'. Open tasks: \(open.joined(separator: "; ")).", [])
            }
            return ("Marked “\(r.title)” as done.", [])

        default:
            return ("Unknown tool '\(name)'.", [])
        }
    }

    /// No-CLI fallback: DeepSeek itself writes a complete self-contained HTML page.
    func deepSeekBuildHTML(task: String, context: String) async -> String? {
        let sys = "You are a build agent. Produce a COMPLETE, self-contained HTML document (inline CSS/JS, " +
            "no external assets) for the requested deliverable. Output ONLY raw HTML starting with <!doctype html> " +
            "— no markdown fences, no commentary."
        let user = "Deliverable: \(task)\n\nGround it ONLY in this context (do not invent facts):\n\(context)"
        let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                   "messages": [["role": "system", "content": sys], ["role": "user", "content": user]],
                                   "temperature": 0.4, "tool_choice": "none"]
        guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
              let resp = try? JSONDecoder().decode(ChatResponse.self, from: data) else { return nil }
        let html = Self.extractHTML(resp.choices.first?.message.content ?? "")
        return html.lowercased().contains("<html") || html.lowercased().contains("<!doctype") ? html : nil
    }

    /// Strip optional ```html fences from a model's HTML output.
    static func extractHTML(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
            if let r = s.range(of: "```", options: .backwards) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The order to try build agents. DeepSeek-native is self-contained, so when it's
    /// preferred we use ONLY it (no CLI dependency). When a CLI is preferred we try it,
    /// then the other CLI (if installed), then DeepSeek as a guaranteed fallback — so
    /// create_artifact always produces something.
    static func buildOrder(preferred: BuildEngine, claudeAvailable: Bool, codexAvailable: Bool) -> [BuildEngine] {
        if preferred == .deepseek { return [.deepseek] }
        func avail(_ e: BuildEngine) -> Bool {
            switch e { case .codex: return codexAvailable; case .claude: return claudeAvailable; case .deepseek: return true }
        }
        let other: BuildEngine = preferred == .codex ? .claude : .codex
        return [preferred, other].filter(avail) + [.deepseek]
    }

    /// A fresh, human-readable folder under ~/Documents/Mnemosyne Artifacts for one build.
    private static func artifactsDir(for task: String) -> String {
        let base = NSHomeDirectory() + "/Documents/Mnemosyne Artifacts"
        let slug = String(task.lowercased().prefix(40)).map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let cleaned = String(String(slug).split(separator: "-").joined(separator: "-").prefix(40))
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(base)/\(stamp)-\(cleaned.isEmpty ? "artifact" : cleaned)"
    }

    /// Resolve a file reference (title or distinctive substring) to matching items —
    /// exact title first, otherwise a case-insensitive substring match.
    private func resolveItems(_ ref: String) async -> [KnowledgeItem] {
        let items = (try? await store.allItems()) ?? []
        let r = ref.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = items.filter { $0.title.lowercased() == r }
        return exact.isEmpty ? items.filter { $0.title.lowercased().contains(r) } : exact
    }

    private static func ambiguity(_ matches: [KnowledgeItem], ref: String) -> String {
        matches.isEmpty
            ? "No file matches '\(ref)'."
            : "Several files match '\(ref)': " + matches.prefix(10).map(\.title).joined(separator: "; ") + ". Which one?"
    }

    /// Pull a boolean field out of a tool call's JSON arguments (accepts true/"true"/"yes"/1).
    static func boolArg(_ argumentsJSON: String, _ key: String) -> Bool {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let b = obj[key] as? Bool { return b }
        if let n = obj[key] as? NSNumber { return n.boolValue }
        if let s = obj[key] as? String { return ["true", "yes", "1", "y"].contains(s.lowercased()) }
        return false
    }

    /// Pull a string field out of a tool call's JSON arguments.
    static func stringArg(_ argumentsJSON: String, _ key: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj[key] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func queryArgument(_ argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = obj["query"] as? String,
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return q
    }

    // MARK: Wire decoding
    struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCall]?
            enum CodingKeys: String, CodingKey { case content, toolCalls = "tool_calls" }
        }
        let choices: [Choice]
    }
    struct ToolCall: Decodable {
        let id: String
        let function: Function
        struct Function: Decodable { let name: String; let arguments: String }
    }
}
