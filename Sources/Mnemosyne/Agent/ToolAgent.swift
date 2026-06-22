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
    • document_outline(item) — the file's exact markdown heading table-of-contents, instant + free.
    • generate_toc(item) — clickable markdown TOC ([Heading](#anchor)) from a file's headings.
    • find_in_item(item, query) — grep one file for a phrase; returns matching lines with line numbers.
    • extract_quotes(item) — pull quoted passages (straight + smart quotes) from a file.
    • extract_ips(item) — pull valid IPv4 addresses from a file (octets validated).
    • extract_domains(item) — pull unique domains from URLs/emails in a file.
    • extract_times(item) — pull times of day (3:30 PM, 09:00, 12pm) from a file.
    • extract_percentages(item) — pull percentages and summarize (count, avg, min, max).
    • read_frontmatter(item) — parse a note's leading '---' YAML metadata block into fields.
    • extract_tables(item) — parse markdown tables (specs, schedules, pricing) into rows.
    • inspect_csv(item) — parse a CSV/TSV spreadsheet: columns, row count, sample rows.
    • csv_to_table(item) — render a CSV/TSV file as an aligned markdown table (first 30 rows).
    • csv_sort(item, column, …) — sort a CSV/TSV by a column (text/numeric, reverse) and show as a table.
    • csv_select(item, columns) — pick/reorder CSV columns (SQL-style projection) and show as a table.
    • csv_group_by(item, group_by, aggregate, op) — SQL GROUP BY with count/sum/mean/min/max.
    • csv_dedupe(item, by?) — remove duplicate rows (whole-row, or first per key column).
    • csv_transpose(item) — swap rows and columns of a CSV/TSV.
    • csv_distinct(item, column) — list the unique values in a column (SELECT DISTINCT).
    • csv_types(item) — infer each column's type (number/boolean/date/text).
    • csv_to_json(item) — convert a CSV/TSV file into a JSON array of objects (header → keys).
    • csv_column_stats(item, column) — aggregate one column: numeric sum/mean/min/max, or top values.
    • csv_filter(item, where) — select rows by a predicate (status = open, amount >= 500, name contains da).
    • inspect_json(item) — describe a JSON file's shape: keys, value types, array lengths, nesting.
    • json_value(item, path) — extract a value by path (address.city, items[0].id, [2]).
    • json_to_table(item) — render a JSON array-of-objects (or object) as an aligned markdown table.
    • json_to_csv(item) — convert a JSON array-of-objects (or object) to CSV (RFC-4180 quoting).
    • json_keys(item) — list every unique key path in a JSON file (user.name, items[].id).
    • json_pluck(item, key) — pull one field from every object in a JSON array (all emails, etc.).
    • json_flatten(item) — flatten nested JSON into dotted 'path = value' lines.
    • json_filter(item, where) — filter a JSON array of objects by a predicate (like csv_filter).
    • text_stats(item) — word/sentence counts, reading time, Flesch readability score.
    • task_progress(item) — markdown checklist completion: done vs pending, percent complete.
    • quick_summary(item) — instant extractive summary (top sentences, no AI model, offline).
    • extract_key_values(item) — pull 'Key: Value' metadata pairs (Status: Done, Due: Friday).
    • redact_pii(item) — masked, shareable copy: emails/phones/SSNs → [email]/[phone]/[ssn].
    • scan_secrets(item) — detect leaked credentials (API keys, tokens, private keys), masked.
    • key_phrases(item) — recurring multi-word topics (bigrams/trigrams), richer than keyword_extract.
    • extract_amounts(item) — pull monetary amounts ($, €, USD…) and total them per currency.
    • extract_definitions(item) — pull definition sentences (X means Y, HTTP stands for…) into a glossary.
    • extract_mentions(item) — pull #hashtags and @mentions with counts (ignores emails/headings).
    • parse_url(url) — break a URL into scheme/host/path/query params/fragment (decoded).
    • jwt_decode(token) — decode a JWT's header + payload claims (no signature check).
    • slugify(text) — make a URL/filename-safe slug from a string (accents folded, punctuation collapsed).
    • hash_text(text) — SHA-256 fingerprint of text (checksums, dedup, identical-content checks).
    • base64(text, mode) — base64 encode/decode text (data URIs, tokens, snippets).
    • html_entities(text, mode) — escape/unescape HTML entities (< ↔ &lt;).
    • url_encode(text, mode) — percent-encode/decode text for URLs (hello world ↔ hello%20world).
    • caesar(text, shift) — Caesar/ROT-N cipher a string (default ROT13).
    • nato(text) — spell text in the NATO phonetic alphabet (Alfa Bravo Charlie…).
    • vigenere(text, key, mode) — Vigenère keyword cipher encode/decode.
    • char_frequency(text, top) — letter-frequency analysis (cipher-breaking aid).
    • morse(text, mode) — encode text to Morse code or decode it back (auto-detects).
    • make_checklist(data) — turn a list of items into a markdown checklist (- [ ] …).
    • format_list(text, style) — reformat a list as numbered/bullet/comma/and (Oxford).
    • change_case(text, mode) — convert text to upper/lower/title/sentence case.
    • headline_case(text) — AP/Chicago title case (minor words stay lowercase).
    • acronym(phrase, skip_minor) — make an acronym from a phrase (Portable Document Format → PDF).
    • case_style(text, style) — convert identifier between snake/camel/kebab/pascal case.
    • word_frequency(text, top) — most frequent content words in provided text (stopwords filtered).
    • count_text(text) — characters/words/lines/sentences of provided text.
    • count_occurrences(text, needle, case_sensitive, whole_word) — count how often a word/phrase appears.
    • palindrome(text) — check if text reads the same forwards/backwards (ignoring case/punctuation).
    • anagram(a, b) — check whether two phrases are anagrams (same letters rearranged).
    • reverse(text, mode) — reverse text by characters or by word order.
    • truncate(text, length, mode) — shorten text to N chars or words with an ellipsis.
    • replace_text(text, find, replace) — find/replace in a string with a count (optional case-insensitive).
    • extract_between(text, start, end) — pull spans between two markers (e.g. <b>…</b>).
    • word_diff(a, b) — word-level diff of two texts (added vs removed words).
    • line_diff(a, b) — line-level LCS diff of two text blocks (unified +/- view).
    • extract_fields(text, fields) — pull named fields from text into a table (reliable force-JSON).
    • fill_in(prefix, suffix) — generate the missing middle between two anchors (DeepSeek FIM).
    • deep_reason(question) — answer a hard analytical question with the reasoner model (R1), step-by-step.
    • text_similarity(a, b) — Jaccard word-overlap similarity of two texts (0–100%).
    • edit_distance(a, b) — Levenshtein edit distance + similarity % (typos, fuzzy matching).
    • reindent(text, mode, spaces) — indent each line, or dedent common leading whitespace.
    • wrap_text(text, width) — word-wrap text to a column width (preserves paragraphs).
    • extract_json(text) — pull valid JSON object(s)/array(s) embedded in a larger text.
    • format_json(json, mode) — pretty-print or minify a JSON string.
    • json_merge(a, b, deep) — merge two JSON objects (second wins; deep by default).
    • sort_lines(text, …) — sort lines (alpha/numeric, reverse, unique).
    • compare_lists(a, b, mode) — set ops on two lists (common/only_a/only_b/union).
    • strip_markdown(text) — remove markdown formatting to get plain prose.
    • number_bases(value) — show an integer in decimal/hex/binary/octal (auto-detects 0x/0b/0o).
    • convert_base(value, from, to) — convert an integer between any bases 2–36.
    • number_to_words(value) — spell an integer in English words (1234 → 'one thousand…').
    • number_format(value) — add thousands separators (1234567 → 1,234,567).
    • ordinal(value) — format a number as an ordinal (23 → 23rd).
    • gcd_lcm(a, b) — greatest common divisor and least common multiple of two integers.
    • factorize(value) — prime check or prime factorization (60 → 2 × 2 × 3 × 5).
    • temperature(value, from, to) — convert between °C, °F, and K.
    • color(value) — convert hex ↔ RGB (#FF5733 ↔ rgb(255, 87, 51)).
    • luhn(value) — validate a number's Luhn checksum (cards, IMEIs, IDs).
    • password_strength(password) — entropy-bits + strength label, on-device.
    • validate_email(email) — check whether a string is a well-formed email address.
    • percentage(mode, a, b) — X% of Y / X is what % of Y / % change A→B.
    • roman_numeral(value) — convert Arabic ↔ Roman numerals (auto-detect direction).
    • duration(value) — seconds ↔ human duration (3661 ↔ '1h 1m 1s'; '1:30:00' → seconds).
    • file_size(value) — bytes ↔ human size (1500000 ↔ '1.5 MB'; '2GB' → bytes).
    • date_diff(from, to?) — days between two dates (to defaults to today): countdowns, "how long ago".
    • weekday(date) — the day of the week a YYYY-MM-DD date falls on.
    • add_days(date, days) — date N days from a date (+ weekday); negative goes backward.
    • bar_chart(data) — render an ASCII bar chart from 'label: value' pairs to visualize numbers inline.
    • make_table(data) — format rows into an aligned markdown table (first row = header).
    • number_stats(data) — count/sum/mean/median/min/max/range/stdev over a list of numbers.
    • sparkline(data) — compact one-line trend (▁▂▃▄▅▆▇█) from a number series.
    • quartiles(data) — Q1/median/Q3/IQR of a list of numbers.
    • percentile(data, p) — the Nth percentile of a number list (e.g. p95 latency).
    • z_score(data, value) — standard score of a value vs a number list (or standardize the list).
    • outliers(data, k) — flag outliers in a number list via Tukey's IQR fences.
    • correlation(x, y) — Pearson r between two equal-length number lists.
    • moving_average(data, window) — rolling mean of a number series to reveal its trend.
    • running_total(data) — cumulative sums of a number series (last = grand total).
    • pct_change(data) — period-over-period % change of a number series.
    • histogram(data, bins) — text histogram of a number list's distribution.
    • tally(data) — count occurrences of each distinct value in a list (GROUP BY).
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
            tool("document_outline", "The file's EXACT markdown heading hierarchy as an indented table of contents — instant and free (no model). Use to navigate a long markdown doc; complements outline_item (which summarizes).",
                 ["item": item], required: ["item"]),
            tool("generate_toc", "Build a clickable markdown table of contents from a file's headings — an indented list of [Heading](#anchor) links. Paste at the top of a long doc.",
                 ["item": item], required: ["item"]),
            tool("find_in_item", "Find the lines in ONE file that contain a phrase (case-insensitive) — a within-document grep with line numbers. Use for 'where does this note mention X?' (search_knowledge searches across files instead).",
                 ["item": item, "query": ["type": "string", "description": "The phrase/substring to find within the file."]],
                 required: ["item", "query"]),
            tool("read_frontmatter", "Read the YAML-style frontmatter (the leading '---' metadata block) of a note — keys like title, tags, date. Distinct from extract_key_values (which scans the whole file).",
                 ["item": item], required: ["item"]),
            tool("extract_quotes", "Pull quoted passages from a file — straight (\"…\") and smart (curly) quotes. Use to find citations or highlighted lines in a note.",
                 ["item": item], required: ["item"]),
            tool("extract_ips", "Pull valid IPv4 addresses from a file (logs, configs) — each octet validated 0–255. Use for log analysis.",
                 ["item": item], required: ["item"]),
            tool("extract_domains", "Pull the unique domain names from a file — hosts from URLs and domains from email addresses. Use to see which sites appear in a note.",
                 ["item": item], required: ["item"]),
            tool("extract_times", "Pull times of day from a file — '3:30 PM', '09:00', '12pm'. Validated hours/minutes. Use to find schedule/meeting times.",
                 ["item": item], required: ["item"]),
            tool("extract_percentages", "Pull percentage values from a file ('45%', '12.5 %') and summarize them — count plus average, min, and max. Use for stats/report notes.",
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
            tool("extract_tables", "Pull markdown TABLES out of a file as parsed rows — a doc's densest structured data (specs, schedules, pricing, comparisons). Returns each table's dimensions, headers, and preview rows.",
                 ["item": item], required: ["item"]),
            tool("inspect_csv", "Parse a CSV or TSV file (spreadsheet/export) into columns and rows — auto-detects the delimiter, handles quoted fields with embedded commas/newlines. Reports the column names, row count, and sample rows.",
                 ["item": item], required: ["item"]),
            tool("csv_to_table", "Render a CSV/TSV file as a clean aligned MARKDOWN table for display in the chat (first N rows). Use when the user wants to SEE a spreadsheet, not just its stats.",
                 ["item": item], required: ["item"]),
            tool("csv_sort", "Sort a CSV/TSV file by a column and show the result as a table. Set numeric=true to sort by number, descending=true to reverse. Call inspect_csv first to see the column names.",
                 ["item": item, "column": ["type": "string", "description": "The column header to sort by (case-insensitive)."],
                  "numeric": ["type": "boolean", "description": "Sort by numeric value (default false)."],
                  "descending": ["type": "boolean", "description": "Reverse order (default false)."]],
                 required: ["item", "column"]),
            tool("csv_select", "Pick and reorder columns from a CSV/TSV file (like SQL SELECT col1, col3) and show the result as a table. Use to narrow a wide spreadsheet to the columns you care about.",
                 ["item": item, "columns": ["type": "string", "description": "Comma-separated column names, in the order you want, e.g. 'name, city'."]],
                 required: ["item", "columns"]),
            tool("csv_group_by", "Group a CSV/TSV by a column and aggregate another — like SQL GROUP BY. op is count (default), sum, mean, min, or max; 'aggregate' is required for everything except count. E.g. group_by=region, aggregate=sales, op=sum.",
                 ["item": item,
                  "group_by": ["type": "string", "description": "Column to group rows by."],
                  "aggregate": ["type": "string", "description": "Numeric column to aggregate (not needed for count)."],
                  "op": ["type": "string", "enum": ["count", "sum", "mean", "min", "max"], "description": "Aggregation (default count)."]],
                 required: ["item", "group_by"]),
            tool("csv_dedupe", "Remove duplicate rows from a CSV/TSV — exact whole-row duplicates by default, or keep the first row per 'by' column. Reports how many were removed and shows the result.",
                 ["item": item, "by": ["type": "string", "description": "Optional column to dedupe by (keeps first per value). Omit for exact whole-row dedupe."]],
                 required: ["item"]),
            tool("csv_transpose", "Transpose a CSV/TSV — swap rows and columns so each column becomes a row. Useful for flipping a small table. Shows the result.",
                 ["item": item], required: ["item"]),
            tool("csv_distinct", "List the unique values in a CSV/TSV column (SQL SELECT DISTINCT) — explore what's in a column. Call inspect_csv first to see the column names.",
                 ["item": item, "column": ["type": "string", "description": "The column header (case-insensitive)."]],
                 required: ["item", "column"]),
            tool("csv_types", "Infer the type of each CSV/TSV column — number, boolean, date, text, or empty — by sampling its values. A quick schema view.",
                 ["item": item], required: ["item"]),
            tool("csv_to_json", "Convert a CSV/TSV file into a JSON array of objects (header row → keys; values stay strings). Use to reshape a spreadsheet for an API or further processing.",
                 ["item": item], required: ["item"]),
            tool("csv_column_stats", "Compute aggregate statistics for ONE column of a CSV/TSV file — numeric sum/mean/min/max when the column is numeric, otherwise the most frequent values. Use to answer 'total revenue?', 'most common status?'. Call inspect_csv first to see the column names.",
                 ["item": item, "column": ["type": "string", "description": "The exact column header to analyze (case-insensitive)."]],
                 required: ["item", "column"]),
            tool("csv_filter", "Select the rows of a CSV/TSV file that match a predicate — e.g. 'status = open', 'amount >= 500', 'name contains da'. Operators: = != > < >= <= contains (numeric when both sides are numbers, else case-insensitive text). Returns the matching rows.",
                 ["item": item, "where": ["type": "string", "description": "A predicate like 'column OP value', e.g. 'amount >= 500' or 'status = open'."]],
                 required: ["item", "where"]),
            tool("inspect_json", "Describe the SHAPE/schema of a JSON file (config, API export, log) — top-level type, keys with their value types, array lengths, and nesting. Use to understand an export's structure before reasoning about it.",
                 ["item": item], required: ["item"]),
            tool("json_value", "Extract the value at a path from a JSON file — dot/bracket syntax like 'address.city', 'items[0].id', or '[2]'. Scalars are returned literally; objects/arrays as compact JSON. Call inspect_json first to see the structure.",
                 ["item": item, "path": ["type": "string", "description": "A dot/bracket path, e.g. 'user.name' or 'results[0].score'."]],
                 required: ["item", "path"]),
            tool("json_to_table", "Render a JSON file as an aligned MARKDOWN table — best for an array of objects (a column per key), also handles a single object (key/value) or an array of scalars. Use when the user wants to SEE a JSON export.",
                 ["item": item], required: ["item"]),
            tool("json_to_csv", "Convert a JSON file (array of objects, or a single object) into CSV — proper RFC-4180 quoting. Use to export a JSON response for a spreadsheet.",
                 ["item": item], required: ["item"]),
            tool("json_keys", "List every unique key PATH in a JSON file — 'user.name', 'items[].id' — a flat view of the structure. Pair with json_value to read a path.",
                 ["item": item], required: ["item"]),
            tool("json_pluck", "From a JSON file that's an ARRAY of objects, pull one field from every object — e.g. all 'email' values. Returns the list of values.",
                 ["item": item, "key": ["type": "string", "description": "The object key to pluck from each array element."]],
                 required: ["item", "key"]),
            tool("json_flatten", "Flatten a nested JSON file into dotted 'path = value' lines (a.b, x[0]) — a flat, scannable view of every value.",
                 ["item": item], required: ["item"]),
            tool("json_filter", "Filter a JSON file that's an ARRAY of objects by a predicate — e.g. 'status = active', 'score >= 80'. Operators: = != > < >= <= contains. Shows the matching rows as a table.",
                 ["item": item, "where": ["type": "string", "description": "A predicate like 'key OP value', e.g. 'score >= 80'."]],
                 required: ["item", "where"]),
            tool("text_stats", "Readability + length metrics for a file — word/sentence counts, estimated reading time, and a Flesch Reading Ease score with a plain-language band. Use to answer 'how long is this?' or 'how hard is it to read?'.",
                 ["item": item], required: ["item"]),
            tool("task_progress", "Measure a markdown CHECKLIST's completion in a file — counts done vs pending boxes ([x] vs [ ]) and a percent-complete. Unlike extract_action_items (only open TODOs), this reports the whole list including finished items.",
                 ["item": item], required: ["item"]),
            tool("quick_summary", "An INSTANT extractive summary of a file — picks its most salient existing sentences by word-frequency, no AI model (works offline, no API key). Faster/cheaper than summarize_item; use it for a quick gist or when the model is unavailable.",
                 ["item": item], required: ["item"]),
            tool("extract_key_values", "Pull 'Key: Value' METADATA pairs from a file — note headers / front-matter like 'Status: Done', 'Due: Friday', 'Owner: Sam'. Excludes times and URLs. Use to read a note's structured fields.",
                 ["item": item], required: ["item"]),
            tool("redact_pii", "Produce a SHAREABLE copy of a file with personal identifiers masked — emails, phone numbers, and US SSNs become [email]/[phone]/[ssn]. Reports what was redacted. Use before exporting or quoting a note externally.",
                 ["item": item], required: ["item"]),
            tool("scan_secrets", "Scan a file for leaked CREDENTIALS — API keys (AWS/Google), access tokens (GitHub/Slack), PEM private keys, and password/token assignments. Reports findings with the secret MASKED. Use to check a config or code paste before sharing.",
                 ["item": item], required: ["item"]),
            tool("key_phrases", "Extract the recurring multi-word KEY PHRASES (topics) from a file — e.g. 'machine learning', 'quarterly report'. A richer topical fingerprint than keyword_extract (single words). Use to grasp or label what a document is about.",
                 ["item": item], required: ["item"]),
            tool("extract_amounts", "Pull MONETARY amounts from a file (receipts, invoices, expense notes) — $1,200.50, €30, 45 USD — and total them per currency. Use to answer 'how much in total?' or list the charges in a document.",
                 ["item": item], required: ["item"]),
            tool("extract_definitions", "Pull DEFINITION sentences from a file ('X means Y', 'HTTP stands for…', 'a vector is an…') to build a glossary. Offline and pure (define_term does a single model lookup instead).",
                 ["item": item], required: ["item"]),
            tool("extract_mentions", "Pull #hashtags and @mentions from a file with their counts — note tags and people. Correctly ignores email addresses and markdown headings.",
                 ["item": item], required: ["item"]),
            tool("parse_url", "Break a URL into its parts — scheme, host, path, decoded query parameters, and fragment. Use to inspect what a link (e.g. a tracking URL) actually contains.",
                 ["url": ["type": "string", "description": "The URL to parse, e.g. 'https://example.com/p?utm_source=x'."]],
                 required: ["url"]),
            tool("jwt_decode", "Decode a JSON Web Token's header and payload (claims like issuer, subject, expiry, scopes) — base64url, no key needed. Does NOT verify the signature (that requires the secret); it's an inspector, not a validator.",
                 ["token": ["type": "string", "description": "The JWT (header.payload.signature)."]],
                 required: ["token"]),
            tool("slugify", "Turn a string into a URL/filename-safe slug — 'My Great Note!' → 'my-great-note'. Folds accents to ASCII and collapses punctuation. Use for anchors, filenames, or artifact names.",
                 ["text": ["type": "string", "description": "The text to slugify, e.g. a title."]],
                 required: ["text"]),
            tool("hash_text", "Compute the SHA-256 fingerprint of some text — for checksums, deduplication, or checking whether two pieces of text are identical. Returns the full hex hash and a short 8-char fingerprint.",
                 ["text": ["type": "string", "description": "The text to hash."]],
                 required: ["text"]),
            tool("base64", "Base64-encode or -decode text. Set mode to 'encode' (default) or 'decode'. Use for data URIs, tokens, or decoding an encoded snippet.",
                 ["text": ["type": "string", "description": "The text to encode, or the base64 to decode."],
                  "mode": ["type": "string", "enum": ["encode", "decode"], "description": "encode (default) or decode."]],
                 required: ["text"]),
            tool("html_entities", "Escape or unescape HTML entities (< ↔ &lt;, & ↔ &amp;, etc.). Set mode to 'escape' (default) to make text HTML-safe, or 'unescape' to decode.",
                 ["text": ["type": "string", "description": "The text to escape or unescape."],
                  "mode": ["type": "string", "enum": ["escape", "unescape"], "description": "escape (default) or unescape."]],
                 required: ["text"]),
            tool("url_encode", "Percent-encode or -decode text for URLs/query strings. Set mode to 'encode' (default) or 'decode'. E.g. 'hello world' → 'hello%20world'.",
                 ["text": ["type": "string", "description": "The text to encode, or the percent-encoded text to decode."],
                  "mode": ["type": "string", "enum": ["encode", "decode"], "description": "encode (default) or decode."]],
                 required: ["text"]),
            tool("caesar", "Caesar-cipher (ROT-N) a string — shift each letter by 'shift' positions (default 13 = ROT13). Case and non-letters preserved. ROT13 decodes itself.",
                 ["text": ["type": "string", "description": "The text to shift."],
                  "shift": ["type": "integer", "description": "Letters to shift (default 13). Negative to decode a forward shift."]],
                 required: ["text"]),
            tool("nato", "Spell text using the NATO phonetic alphabet (Alfa, Bravo, Charlie…) — read out a code, name, or confirmation number unambiguously over the phone. Digits and punctuation handled too.",
                 ["text": ["type": "string", "description": "The text to spell out phonetically."]],
                 required: ["text"]),
            tool("morse", "Encode text to International Morse code or decode Morse back to text. Letters separated by spaces, words by ' / '. Auto-detects direction; set 'mode' to 'encode'/'decode' to force it.",
                 ["text": ["type": "string", "description": "Plain text to encode, or dot/dash Morse to decode."],
                  "mode": ["type": "string", "description": "'encode', 'decode', or omit to auto-detect."]],
                 required: ["text"]),
            tool("vigenere", "Vigenère cipher — encode or decode text with a keyword (a stronger classic cipher than Caesar). Case preserved, non-letters pass through. Set 'mode' to 'encode' (default) or 'decode'.",
                 ["text": ["type": "string", "description": "The text to encode or decode."],
                  "key": ["type": "string", "description": "The keyword (letters only are used)."],
                  "mode": ["type": "string", "description": "'encode' (default) or 'decode'."]],
                 required: ["text", "key"]),
            tool("char_frequency", "Letter-frequency analysis of text — counts each A–Z letter (case-insensitive) with percentages, sorted most→least common. The classic first step in breaking a substitution/Caesar cipher. Set 'top' to cap rows.",
                 ["text": ["type": "string", "description": "The text to analyze."],
                  "top": ["type": "integer", "description": "Max letters to show (default 26)."]],
                 required: ["text"]),
            tool("make_checklist", "Turn a list of items into a markdown checklist (- [ ] item). Pass items one per line; existing bullets/numbers are stripped and a leading [x] is kept as done. Use to convert notes or action items into a task list.",
                 ["data": ["type": "string", "description": "Items, one per line, e.g. 'buy milk\\ncall Sam'."]],
                 required: ["data"]),
            tool("format_list", "Reformat a list of items — style 'numbered', 'bullet', 'comma', or 'and' (Oxford-comma sentence). Existing bullets/numbers are stripped first.",
                 ["text": ["type": "string", "description": "Items, one per line."],
                  "style": ["type": "string", "enum": ["numbered", "bullet", "comma", "and"], "description": "Output style."]],
                 required: ["text", "style"]),
            tool("change_case", "Convert text case — set mode to 'upper', 'lower', 'title', or 'sentence'. Use to clean up or normalize a heading or pasted text.",
                 ["text": ["type": "string", "description": "The text to convert."],
                  "mode": ["type": "string", "enum": ["upper", "lower", "title", "sentence"], "description": "Target case."]],
                 required: ["text", "mode"]),
            tool("headline_case", "Title-case a headline AP/Chicago-style — major words capitalized, short articles/conjunctions/prepositions lowercased (unless first or last). E.g. 'the lord of the rings' → 'The Lord of the Rings'.",
                 ["text": ["type": "string", "description": "The headline/title to format."]],
                 required: ["text"]),
            tool("acronym", "Make an acronym from a phrase — first letter of each word, uppercased. E.g. 'Portable Document Format' → 'PDF'. Set skip_minor=true to drop words like 'the', 'of'.",
                 ["phrase": ["type": "string", "description": "The phrase to acronymize."],
                  "skip_minor": ["type": "boolean", "description": "Skip minor words (the, of, and…). Default false."]],
                 required: ["phrase"]),
            tool("case_style", "Convert an identifier between styles — 'snake' (snake_case), 'camel' (camelCase), 'kebab' (kebab-case), or 'pascal' (PascalCase). Auto-detects the input's words.",
                 ["text": ["type": "string", "description": "The identifier/phrase to convert."],
                  "style": ["type": "string", "enum": ["snake", "camel", "kebab", "pascal"], "description": "Target style."]],
                 required: ["text", "style"]),
            tool("word_frequency", "Count the most frequent content words in some text (stopwords filtered) — a quick topical fingerprint. Set 'top' to cap how many to return (default 10).",
                 ["text": ["type": "string", "description": "The text to analyze."],
                  "top": ["type": "integer", "description": "How many top words to return (default 10)."]],
                 required: ["text"]),
            tool("count_text", "Count characters (with/without spaces), words, lines, and sentences of some text. Quick stats on a pasted passage.",
                 ["text": ["type": "string", "description": "The text to measure."]],
                 required: ["text"]),
            tool("count_occurrences", "Count how many times a word or phrase appears in some text. Case-insensitive by default; set case_sensitive=true or whole_word=true to refine. Overlapping matches aren't double-counted.",
                 ["text": ["type": "string", "description": "The text to search."],
                  "needle": ["type": "string", "description": "The word/phrase to count."],
                  "case_sensitive": ["type": "boolean", "description": "Match case exactly (default false)."],
                  "whole_word": ["type": "boolean", "description": "Only count whole-word matches (default false)."]],
                 required: ["text", "needle"]),
            tool("palindrome", "Check whether text reads the same forwards and backwards (ignoring case and punctuation). E.g. 'A man, a plan, a canal: Panama'.",
                 ["text": ["type": "string", "description": "The text to check."]],
                 required: ["text"]),
            tool("anagram", "Check whether two phrases are anagrams — same letters rearranged (case, spaces, and punctuation ignored). E.g. 'Listen' / 'Silent'.",
                 ["a": ["type": "string", "description": "First phrase."],
                  "b": ["type": "string", "description": "Second phrase."]],
                 required: ["a", "b"]),
            tool("reverse", "Reverse text. mode 'chars' (default) reverses the characters; mode 'words' reverses the word order.",
                 ["text": ["type": "string", "description": "The text to reverse."],
                  "mode": ["type": "string", "enum": ["chars", "words"], "description": "chars (default) or words."]],
                 required: ["text"]),
            tool("truncate", "Shorten text to a length with an ellipsis. mode 'chars' (default) limits characters; mode 'words' limits words. Ellipsis added only if cut.",
                 ["text": ["type": "string", "description": "The text to truncate."],
                  "length": ["type": "integer", "description": "Max characters (or words)."],
                  "mode": ["type": "string", "enum": ["chars", "words"], "description": "chars (default) or words."]],
                 required: ["text", "length"]),
            tool("replace_text", "Find and replace text within a string — replaces every occurrence of 'find' with 'replace' and reports the count. Set case_insensitive to true to ignore case.",
                 ["text": ["type": "string", "description": "The text to transform."],
                  "find": ["type": "string", "description": "The substring to find."],
                  "replace": ["type": "string", "description": "The replacement (may be empty to delete)."],
                  "case_insensitive": ["type": "boolean", "description": "Ignore case when matching (default false)."]],
                 required: ["text", "find", "replace"]),
            tool("extract_between", "Extract every span of text between a start and end marker — e.g. between '<b>' and '</b>', or '[' and ']'. Use to pull fields out of templated or markup text.",
                 ["text": ["type": "string", "description": "The text to scan."],
                  "start": ["type": "string", "description": "The opening marker."],
                  "end": ["type": "string", "description": "The closing marker."]],
                 required: ["text", "start", "end"]),
            tool("word_diff", "Compare two texts at the WORD level — which words were added vs removed (case-insensitive). Complements the line-level diff tools.",
                 ["a": ["type": "string", "description": "The first text."],
                  "b": ["type": "string", "description": "The second text."]],
                 required: ["a", "b"]),
            tool("line_diff", "Line-level diff between two text blocks — a unified-style view (unchanged ' ', removed '-', added '+') using LCS matching. Use to compare two versions of a note, config, or list.",
                 ["a": ["type": "string", "description": "The original text (one item per line)."],
                  "b": ["type": "string", "description": "The new text to compare against A."]],
                 required: ["a", "b"]),
            tool("extract_fields", "Pull named fields out of free text into a structured table — e.g. extract 'name, date, amount, vendor' from a receipt or email. Uses DeepSeek's force-JSON mode for reliable structure. Missing fields show as —.",
                 ["text": ["type": "string", "description": "The source text to extract from."],
                  "fields": ["type": "string", "description": "Field names to extract, comma-separated (e.g. 'name, date, total')."]],
                 required: ["text", "fields"]),
            tool("fill_in", "Fill in the gap between a prefix and a suffix — generate the missing middle (DeepSeek fill-in-the-middle). Great for completing a function body, a paragraph, or a config block between two anchors.",
                 ["prefix": ["type": "string", "description": "The text/code BEFORE the gap."],
                  "suffix": ["type": "string", "description": "The text/code AFTER the gap (optional)."]],
                 required: ["prefix"]),
            tool("deep_reason", "Answer a HARD analytical question with DeepSeek's reasoner model (R1) — it thinks step-by-step before answering. Use for proofs, multi-step logic, trade-off analysis, debugging, or anything needing careful reasoning (not quick lookups). Returns the answer plus its reasoning.",
                 ["question": ["type": "string", "description": "The analytical question to reason through."]],
                 required: ["question"]),
            tool("text_similarity", "Measure how similar two texts are — a Jaccard word-overlap ratio (0–100%). Use to gauge how alike two notes/passages are.",
                 ["a": ["type": "string", "description": "The first text."],
                  "b": ["type": "string", "description": "The second text."]],
                 required: ["a", "b"]),
            tool("edit_distance", "Levenshtein edit distance between two strings — the minimum single-character edits to turn one into the other, plus a similarity %. Good for typos / fuzzy matching.",
                 ["a": ["type": "string", "description": "The first string."],
                  "b": ["type": "string", "description": "The second string."]],
                 required: ["a", "b"]),
            tool("reindent", "Indent or dedent a block of text. mode 'indent' adds 'spaces' leading spaces to each line; mode 'dedent' strips the common leading whitespace. Handy for code snippets.",
                 ["text": ["type": "string", "description": "The text to reindent."],
                  "mode": ["type": "string", "enum": ["indent", "dedent"], "description": "indent or dedent."],
                  "spaces": ["type": "integer", "description": "Spaces to add for 'indent' (default 2)."]],
                 required: ["text", "mode"]),
            tool("wrap_text", "Word-wrap text to a column width (default 80), preserving blank-line paragraph breaks. Use to reflow prose or comments.",
                 ["text": ["type": "string", "description": "The text to wrap."],
                  "width": ["type": "integer", "description": "Column width (default 80)."]],
                 required: ["text"]),
            tool("extract_json", "Pull valid JSON object(s) or array(s) embedded in a larger text — JSON buried in logs, model output, or prose. Returns each JSON block found.",
                 ["text": ["type": "string", "description": "The text that may contain JSON."]],
                 required: ["text"]),
            tool("format_json", "Pretty-print or minify a JSON string. Set mode to 'pretty' (default, indented + sorted keys) or 'minify' (compact). Returns an error if the JSON is invalid.",
                 ["json": ["type": "string", "description": "The JSON text to format."],
                  "mode": ["type": "string", "enum": ["pretty", "minify"], "description": "pretty (default) or minify."]],
                 required: ["json"]),
            tool("json_merge", "Merge two JSON objects — the second wins on conflicts. Deep by default (recurses into nested objects); set deep=false for a top-level-only merge. Use to combine configs/settings.",
                 ["a": ["type": "string", "description": "Base JSON object."],
                  "b": ["type": "string", "description": "JSON object to merge in (wins on conflicts)."],
                  "deep": ["type": "boolean", "description": "Recurse into nested objects (default true)."]],
                 required: ["a", "b"]),
            tool("sort_lines", "Sort the lines of a block of text — alphabetical by default. Set numeric=true to sort by number, descending=true to reverse, unique=true to drop duplicates. Blank lines are removed.",
                 ["text": ["type": "string", "description": "The lines to sort (one per line)."],
                  "numeric": ["type": "boolean", "description": "Sort by numeric value (default false)."],
                  "descending": ["type": "boolean", "description": "Reverse order (default false)."],
                  "unique": ["type": "boolean", "description": "Remove duplicate lines (default false)."]],
                 required: ["text"]),
            tool("compare_lists", "Set operations between two newline-separated lists — mode 'common' (in both), 'only_a' (in A not B), 'only_b' (in B not A), or 'union' (all). Use to compare two sets of names/tags/values.",
                 ["a": ["type": "string", "description": "List A, one item per line."],
                  "b": ["type": "string", "description": "List B, one item per line."],
                  "mode": ["type": "string", "enum": ["common", "only_a", "only_b", "union"], "description": "The set operation (default common)."]],
                 required: ["a", "b"]),
            tool("strip_markdown", "Strip markdown formatting from text to get plain prose — removes headings, bold/italic, links, images, inline code, bullets, and quotes. Use to get a clean text version.",
                 ["text": ["type": "string", "description": "The markdown text to strip."]],
                 required: ["text"]),
            tool("number_bases", "Show an integer in decimal, hex, binary, and octal. Input may be decimal or prefixed (0x.., 0b.., 0o..). E.g. '255' or '0xff'.",
                 ["value": ["type": "string", "description": "The integer, decimal or 0x/0b/0o-prefixed."]],
                 required: ["value"]),
            tool("convert_base", "Convert an integer between any numeric bases 2–36 — e.g. value=FF, from=16, to=10 → 255.",
                 ["value": ["type": "string", "description": "The number, in base 'from'."],
                  "from": ["type": "integer", "description": "Source base (2–36)."],
                  "to": ["type": "integer", "description": "Target base (2–36)."]],
                 required: ["value", "from", "to"]),
            tool("number_to_words", "Spell an integer in English words — e.g. 1234 → 'one thousand two hundred thirty-four'. Handles zero and negatives, up to trillions.",
                 ["value": ["type": "string", "description": "The integer to spell out."]],
                 required: ["value"]),
            tool("number_format", "Add thousands separators to a number — '1234567' → '1,234,567'. Keeps sign and decimals.",
                 ["value": ["type": "string", "description": "The number to format."]],
                 required: ["value"]),
            tool("ordinal", "Format a number as an ordinal — 1 → 1st, 23 → 23rd, 111 → 111th (handles the 11/12/13 exceptions).",
                 ["value": ["type": "string", "description": "The integer to make ordinal."]],
                 required: ["value"]),
            tool("gcd_lcm", "Compute the greatest common divisor and least common multiple of two integers. E.g. a=12, b=18 → gcd 6, lcm 36.",
                 ["a": ["type": "integer", "description": "First integer."],
                  "b": ["type": "integer", "description": "Second integer."]],
                 required: ["a", "b"]),
            tool("factorize", "Tell whether a number is prime, or give its prime factorization — e.g. 60 → 2 × 2 × 3 × 5.",
                 ["value": ["type": "integer", "description": "The integer to factorize (2 … 1e12)."]],
                 required: ["value"]),
            tool("temperature", "Convert a temperature between Celsius, Fahrenheit, and Kelvin. E.g. value=100, from=C, to=F → 212.",
                 ["value": ["type": "number", "description": "The temperature value."],
                  "from": ["type": "string", "description": "Source unit: C, F, or K."],
                  "to": ["type": "string", "description": "Target unit: C, F, or K."]],
                 required: ["value", "from", "to"]),
            tool("color", "Convert a color between hex and RGB — '#FF5733' → rgb(255, 87, 51), or '255,87,51' → #FF5733. Supports shorthand like #fff.",
                 ["value": ["type": "string", "description": "A hex color (#RRGGBB or #RGB) or 'r,g,b'."]],
                 required: ["value"]),
            tool("luhn", "Check whether a number passes the Luhn checksum (used by credit-card numbers, IMEIs, and many IDs). Spaces and dashes are ignored.",
                 ["value": ["type": "string", "description": "The number to validate."]],
                 required: ["value"]),
            tool("password_strength", "Estimate a password's strength on-device — entropy in bits plus a label (very weak…very strong), based on length and the character classes used. Never sent anywhere.",
                 ["password": ["type": "string", "description": "The password to evaluate."]],
                 required: ["password"]),
            tool("validate_email", "Check whether a string is a well-formed email address (local@domain.tld). Distinct from extract_emails, which finds them in text.",
                 ["email": ["type": "string", "description": "The email address to validate."]],
                 required: ["email"]),
            tool("percentage", "Everyday percentage math. mode 'of' → a% of b; 'what_percent' → a is what % of b; 'change' → percent change from a to b. E.g. mode=of, a=10, b=200.",
                 ["mode": ["type": "string", "enum": ["of", "what_percent", "change"], "description": "Which calculation."],
                  "a": ["type": "number", "description": "First number."],
                  "b": ["type": "number", "description": "Second number."]],
                 required: ["mode", "a", "b"]),
            tool("roman_numeral", "Convert between Arabic and Roman numerals (1–3999), direction auto-detected. E.g. '1994' → MCMXCIV, or 'IV' → 4.",
                 ["value": ["type": "string", "description": "A number (1–3999) or a Roman numeral."]],
                 required: ["value"]),
            tool("duration", "Convert between seconds and human-readable durations. A plain number is read as seconds → '1h 1m 1s'; a duration like '1h 30m' or '1:30:00' → seconds.",
                 ["value": ["type": "string", "description": "Seconds (e.g. '3661') or a duration ('1h 30m', '1:30:00')."]],
                 required: ["value"]),
            tool("file_size", "Convert between a byte count and a human-readable size (decimal, like Finder). A plain number of bytes → '1.5 MB'; a size like '1.5 MB' or '2GB' → bytes.",
                 ["value": ["type": "string", "description": "Bytes (e.g. '1500000') or a size ('1.5 MB', '2GB')."]],
                 required: ["value"]),
            tool("weekday", "What day of the week a date falls on (YYYY-MM-DD) — e.g. '2026-06-22' → Monday. Pure calendar math; works for any past or future date.",
                 ["date": ["type": "string", "description": "A date in YYYY-MM-DD form."]],
                 required: ["date"]),
            tool("date_diff", "Count the days between two dates (YYYY-MM-DD). Omit 'to' to count from 'from' until today — e.g. 'how many days until 2026-12-25?'.",
                 ["from": ["type": "string", "description": "Start date, YYYY-MM-DD."],
                  "to": ["type": "string", "description": "End date, YYYY-MM-DD. Defaults to today if omitted."]],
                 required: ["from"]),
            tool("add_days", "Compute the date a number of days from a given date (YYYY-MM-DD) — negative goes backward. Returns the resulting date and its weekday. E.g. 'what's the date 30 days after 2026-06-15?'.",
                 ["date": ["type": "string", "description": "Start date, YYYY-MM-DD."],
                  "days": ["type": "integer", "description": "Days to add (negative to subtract)."]],
                 required: ["date", "days"]),
            tool("bar_chart", "Render a horizontal ASCII bar chart to VISUALIZE numbers in the chat — pass 'label: value' pairs (comma- or newline-separated), e.g. 'Jan: 8, Feb: 5, Mar: 3'. Great for showing column stats, trends, or tallies you computed.",
                 ["data": ["type": "string", "description": "Label:value pairs, comma- or newline-separated, e.g. 'Q1: 12, Q2: 19'. Plain numbers only (no thousands separators)."]],
                 required: ["data"]),
            tool("make_table", "Format rows into a clean aligned MARKDOWN table — pass newline-separated rows, cells pipe- or comma-separated, first row = header. Use to present a list or result tidily in the chat.",
                 ["data": ["type": "string", "description": "Newline-separated rows; cells comma- or pipe-separated. First row is the header. E.g. 'Name, Age\\nAda, 36'."]],
                 required: ["data"]),
            tool("number_stats", "Descriptive statistics over a list of numbers you provide — count, sum, mean, median, min, max, range, and standard deviation. Pass values separated by commas or spaces, e.g. '12, 19, 7, 23'.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines, e.g. '12 19 7 23'."]],
                 required: ["data"]),
            tool("sparkline", "Render a compact one-line trend (▁▂▃▄▅▆▇█) from a number series — a glanceable inline trend (e.g. activity over time). Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines, e.g. '3 5 4 8 6 9'."]],
                 required: ["data"]),
            tool("quartiles", "Compute the quartiles of a list of numbers — Q1, median, Q3, and the interquartile range (IQR). Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."]],
                 required: ["data"]),
            tool("percentile", "Compute the Nth percentile of a list of numbers (linear interpolation, like NumPy) — e.g. the 95th percentile of latencies. Set 'p' (0–100, default 50 = median). Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
                  "p": ["type": "string", "description": "Percentile 0–100 (default 50)."]],
                 required: ["data"]),
            tool("z_score", "Compute the z-score of a value against a list of numbers — how many standard deviations from the mean (population σ). Pass 'value' to score one number, or omit it to standardize the whole list. Values separated by commas/spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
                  "value": ["type": "string", "description": "A single number to score (optional; omit to standardize the list)."]],
                 required: ["data"]),
            tool("histogram", "Render a text histogram of a number list — buckets the values into bins and shows the distribution. Set 'bins' (default 10). Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
                  "bins": ["type": "integer", "description": "Number of bins (default 10)."]],
                 required: ["data"]),
            tool("outliers", "Detect outliers in a list of numbers using Tukey's IQR fences — flags values far below Q1 or above Q3. Set 'k' (default 1.5; use 3 for extreme-only). Needs at least 4 values. Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
                  "k": ["type": "string", "description": "Fence multiplier (default 1.5; 3 = extreme outliers only)."]],
                 required: ["data"]),
            tool("correlation", "Pearson correlation coefficient (r, −1…1) between two equal-length number lists — how strongly two series move together. Pass 'x' and 'y' as numbers separated by commas or spaces.",
                 ["x": ["type": "string", "description": "First series, numbers separated by commas/spaces/newlines."],
                  "y": ["type": "string", "description": "Second series, same length as x."]],
                 required: ["x", "y"]),
            tool("moving_average", "Smooth a number series with a simple moving average (rolling mean) over a window — reveals the trend. Set 'window' (default 3). Returns one value per window position. Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."],
                  "window": ["type": "integer", "description": "Window size (default 3)."]],
                 required: ["data"]),
            tool("pct_change", "Period-over-period percentage change of a number series — how each value compares to the previous one (e.g. month-over-month growth). Returns n−1 values; a step after a zero is n/a. Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."]],
                 required: ["data"]),
            tool("running_total", "Cumulative (running) totals of a number series — each value is the sum so far; the last is the grand total. Great for finances/progress. Pass values separated by commas or spaces.",
                 ["data": ["type": "string", "description": "Numbers separated by commas/spaces/newlines."]],
                 required: ["data"]),
            tool("tally", "Count how often each distinct value appears in a list (a GROUP BY) — statuses, tags, names. Pass values one per line (or comma-separated). Returns a frequency table; pair with bar_chart to visualize it.",
                 ["data": ["type": "string", "description": "Values one per line or comma-separated, e.g. 'open\\nopen\\nclosed'."]],
                 required: ["data"]),
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
        // Build the round client once. With no test override, wire the DeepSeek-native
        // reasoning sink so `deepseek-reasoner`'s chain-of-thought surfaces as a live
        // "thinking" line in the activity trace (a no-op for deepseek-chat, which has none).
        let roundClient: any Fathom.LLMClient = llmOverride ?? AgentLLMClient(
            deepSeek: deepSeek, temperature: temperature,
            onReasoning: { reasoning in
                if let snip = DeepSeekReasoning.snippet(reasoning) { onStatus("💭 " + snip) }
            },
            onUsage: { usage in
                if let note = DeepSeekUsage.cacheNote(usage) { onStatus("⚡︎ " + note) }
            })
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
            let completion = try await roundClient.complete(
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

        case "extract_quotes":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding quotes in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = QuoteExtractor.summary(full) else {
                return ("No quoted passages found in '\(it.title)'.", [])
            }
            return ("Quotes in '\(it.title)':\n\(summary)", [])

        case "extract_ips":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding IP addresses in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = IPExtractor.summary(full) else {
                return ("No IPv4 addresses found in '\(it.title)'.", [])
            }
            return ("IPs in '\(it.title)':\n\(summary)", [])

        case "extract_domains":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding domains in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = DomainExtractor.summary(full) else {
                return ("No domains (URLs/emails) found in '\(it.title)'.", [])
            }
            return ("Domains in '\(it.title)':\n\(summary)", [])

        case "extract_times":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding times in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = TimeExtractor.summary(full) else {
                return ("No times of day found in '\(it.title)'.", [])
            }
            return ("Times in '\(it.title)':\n\(summary)", [])

        case "extract_percentages":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding percentages in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = PercentExtractor.summary(full) else {
                return ("No percentages found in '\(it.title)'.", [])
            }
            return ("Percentages in '\(it.title)':\n\(summary)", [])

        case "read_frontmatter":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading frontmatter in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = Frontmatter.summary(full) else {
                return ("'\(it.title)' has no frontmatter (a leading '---' metadata block).", [])
            }
            return ("'\(it.title)':\n\(summary)", [])

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

        case "extract_tables":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding tables in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = TableExtractor.summary(text) else {
                return ("No markdown tables found in '\(it.title)'.", [])
            }
            return ("Tables in '\(it.title)':\n\(summary)", [])

        case "inspect_csv":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Inspecting \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = DelimitedParser.summary(text) else {
                return ("'\(it.title)' doesn't parse as CSV/TSV (no rows found).", [])
            }
            return ("'\(it.title)':\n\(summary)", [])

        case "csv_to_table":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Rendering \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard !rows.isEmpty else { return ("'\(it.title)' has no rows to render.", []) }
            let maxRows = 30
            let clamped = Array(rows.prefix(maxRows + 1))   // header + up to maxRows data rows
            guard let table = MarkdownTable.tableFrom(clamped) else {
                return ("Couldn't render '\(it.title)' as a table.", [])
            }
            let note = rows.count > maxRows + 1 ? "\n…(\(rows.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title):\n\(table)\(note)", [])

        case "csv_sort":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let column = arg("column"), !column.isEmpty else { return ("Missing 'column'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Sorting \(it.title) by \(column)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows to sort.", []) }
            func flag(_ k: String) -> Bool { (arg(k) ?? "false").lowercased() == "true" }
            guard let sorted = CSVSorter.sort(header: header, rows: Array(rows.dropFirst()), column: column,
                                              descending: flag("descending"), numeric: flag("numeric")) else {
                return ("Column '\(column)' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 30
            let clamped = Array(sorted.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else { return ("Couldn't render the sorted table.", []) }
            let note = sorted.count > maxRows + 1 ? "\n…(\(sorted.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title) sorted by \(column):\n\(table)\(note)", [])

        case "csv_select":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let colsArg = arg("columns"), !colsArg.isEmpty else { return ("Missing 'columns'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Selecting columns from \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            let columns = colsArg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let projected = CSVProjector.select(header: header, rows: Array(rows.dropFirst()), columns: columns) else {
                return ("One or more columns not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 30
            let clamped = Array(projected.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else { return ("Couldn't render the selected columns.", []) }
            let note = projected.count > maxRows + 1 ? "\n…(\(projected.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title) — selected columns:\n\(table)\(note)", [])

        case "csv_group_by":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let groupCol = arg("group_by"), !groupCol.isEmpty else { return ("Missing 'group_by'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            let op = arg("op") ?? "count"
            onStatus("Grouping \(it.title) by \(groupCol)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            guard let grouped = CSVGroupBy.group(header: header, rows: Array(rows.dropFirst()),
                                                 groupColumn: groupCol, aggColumn: arg("aggregate"), op: op) else {
                return ("Couldn't group '\(it.title)' — check the column names and that 'aggregate' is set for \(op). Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 40
            let clamped = Array(grouped.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else { return ("Couldn't render the grouped table.", []) }
            let note = grouped.count > maxRows + 1 ? "\n…(\(grouped.count - 1 - maxRows) more groups)" : ""
            return ("\(it.title) grouped by \(groupCol):\n\(table)\(note)", [])

        case "csv_dedupe":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Deduping \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            guard let (kept, removed) = CSVDedupe.dedupe(header: header, rows: Array(rows.dropFirst()), keyColumn: arg("by")) else {
                return ("Column '\(arg("by") ?? "")' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 30
            let out = [header] + kept
            guard let table = MarkdownTable.tableFrom(Array(out.prefix(maxRows + 1))) else { return ("Couldn't render the result.", []) }
            let more = out.count > maxRows + 1 ? "\n…(\(out.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title) — removed \(removed) duplicate row(s), \(kept.count) remain:\n\(table)\(more)", [])

        case "csv_transpose":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Transposing \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            let transposed = CSVTranspose.transpose(rows)
            guard !transposed.isEmpty, let table = MarkdownTable.tableFrom(Array(transposed.prefix(31))) else {
                return ("'\(it.title)' has no rows to transpose.", [])
            }
            let note = transposed.count > 31 ? "\n…(\(transposed.count - 31) more rows)" : ""
            return ("\(it.title) transposed:\n\(table)\(note)", [])

        case "csv_distinct":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let column = arg("column"), !column.isEmpty else { return ("Missing 'column'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding distinct \(column) in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            guard let values = CSVDistinct.values(header: header, rows: Array(rows.dropFirst()), column: column) else {
                return ("Column '\(column)' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            guard !values.isEmpty else { return ("Column '\(column)' has no values.", []) }
            return ("\(values.count) distinct value(s) in '\(column)':\n" + values.prefix(100).map { "  \($0)" }.joined(separator: "\n"), [])

        case "csv_types":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Inferring column types in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            let types = CSVTypes.infer(header: header, rows: Array(rows.dropFirst()))
            return ("Column types in '\(it.title)':\n" + types.map { "  \($0.column): \($0.type)" }.joined(separator: "\n"), [])

        case "csv_to_json":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Converting \(it.title) to JSON…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            let maxRows = 100
            let clamped = Array(rows.prefix(maxRows + 1))
            guard let json = CSVConverter.toJSON(clamped) else {
                return ("'\(it.title)' has no rows to convert.", [])
            }
            let note = rows.count > maxRows + 1 ? "\n…(showing first \(maxRows) of \(rows.count - 1) rows)" : ""
            return ("\(it.title) as JSON:\n```json\n\(json)\n```\(note)", [])

        case "json_to_table":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Rendering \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let jsonRows = JSONTable.rows(from: text) else {
                return ("'\(it.title)' isn't JSON that can be tabulated (need an array of objects, an object, or an array).", [])
            }
            let maxRows = 30
            let clamped = Array(jsonRows.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else {
                return ("Couldn't render '\(it.title)' as a table.", [])
            }
            let note = jsonRows.count > maxRows + 1 ? "\n…(\(jsonRows.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title):\n\(table)\(note)", [])

        case "json_to_csv":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Converting \(it.title) to CSV…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let jsonRows = JSONTable.rows(from: text) else {
                return ("'\(it.title)' isn't JSON that can be converted to CSV (need an array of objects, an object, or an array).", [])
            }
            let maxRows = 100
            let clamped = Array(jsonRows.prefix(maxRows + 1))
            guard let csv = CSVConverter.toCSV(clamped) else {
                return ("'\(it.title)' has no rows to convert.", [])
            }
            let note = jsonRows.count > maxRows + 1 ? "\n…(showing first \(maxRows) of \(jsonRows.count - 1) rows)" : ""
            return ("\(it.title) as CSV:\n```\n\(csv)\n```\(note)", [])

        case "json_keys":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Listing JSON keys in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let paths = JSONKeys.paths(text), !paths.isEmpty else {
                return ("'\(it.title)' isn't a JSON object/array with keys.", [])
            }
            return ("\(paths.count) key path(s) in '\(it.title)':\n" + paths.map { "  \($0)" }.joined(separator: "\n"), [])

        case "json_pluck":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let key = arg("key"), !key.isEmpty else { return ("Missing 'key'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Plucking \(key) from \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let values = JSONPluck.pluck(text, key: key) else {
                return ("'\(it.title)' isn't a JSON array of objects.", [])
            }
            guard !values.isEmpty else { return ("No object in '\(it.title)' has the key '\(key)'.", []) }
            return ("\(values.count) value(s) for '\(key)':\n" + values.prefix(100).map { "  \($0)" }.joined(separator: "\n"), [])

        case "json_flatten":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Flattening JSON in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let pairs = JSONFlatten.flatten(text), !pairs.isEmpty else {
                return ("'\(it.title)' isn't JSON with values to flatten.", [])
            }
            let body = pairs.prefix(150).map { "  \($0.path) = \($0.value)" }.joined(separator: "\n")
            let more = pairs.count > 150 ? "\n  …(+\(pairs.count - 150) more)" : ""
            return ("\(pairs.count) leaf value(s) in '\(it.title)':\n\(body)\(more)", [])

        case "json_filter":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let predicate = arg("where"), !predicate.isEmpty else { return ("Missing 'where' predicate.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Filtering JSON in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            switch JSONFilter.filter(text, where: predicate) {
            case .badJSON:
                return ("'\(it.title)' isn't a JSON array/object that can be filtered.", [])
            case .badPredicate:
                return ("Couldn't parse '\(predicate)'. Use 'key OP value', e.g. 'score >= 80'.", [])
            case .noColumn(let cols):
                return ("Key not found in '\(it.title)'. Keys: \(cols.joined(separator: ", ")).", [])
            case .ok(let rows):
                guard rows.count > 1 else { return ("No objects in '\(it.title)' match '\(predicate)'.", []) }
                guard let table = MarkdownTable.tableFrom(Array(rows.prefix(31))) else { return ("Couldn't render the result.", []) }
                let note = rows.count > 31 ? "\n…(\(rows.count - 31) more rows)" : ""
                return ("\(rows.count - 1) match(es) in '\(it.title)' for '\(predicate)':\n\(table)\(note)", [])
            }

        case "csv_column_stats":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let column = arg("column"), !column.isEmpty else { return ("Missing 'column'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Analyzing \(column) in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows to analyze.", []) }
            guard let report = ColumnAnalyzer.report(headers: header, rows: Array(rows.dropFirst()), column: column) else {
                return ("Column '\(column)' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            return ("\(it.title) — \(report)", [])

        case "csv_filter":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let predicate = arg("where"), !predicate.isEmpty else { return ("Missing 'where' predicate.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Filtering \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows to filter.", []) }
            let data = Array(rows.dropFirst())
            switch RowFilter.evaluate(headers: header, rows: data, expr: predicate) {
            case .badPredicate:
                return ("Couldn't parse the predicate '\(predicate)'. Use 'column OP value', e.g. 'amount >= 500' or 'status = open'.", [])
            case .noColumn(let cols):
                return ("Column not found in '\(it.title)'. Columns: \(cols.joined(separator: ", ")).", [])
            case .ok(_, let matchedRows):
                guard !matchedRows.isEmpty else {
                    return ("No rows in '\(it.title)' match '\(predicate)' (of \(data.count) rows).", [])
                }
                let preview = matchedRows.prefix(10).map { "  " + $0.joined(separator: " | ") }
                let more = matchedRows.count > 10 ? ["  …(+\(matchedRows.count - 10) more rows)"] : []
                let body = ("[" + header.joined(separator: " | ") + "]\n" + (preview + more).joined(separator: "\n"))
                return ("\(matchedRows.count) of \(data.count) rows in '\(it.title)' match '\(predicate)':\n\(body)", [])
            }

        case "inspect_json":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Inspecting JSON in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let shape = JSONInspector.shape(text) else {
                return ("'\(it.title)' doesn't parse as JSON.", [])
            }
            return ("JSON shape of '\(it.title)':\n\(shape)", [])

        case "json_value":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let path = arg("path"), !path.isEmpty else { return ("Missing 'path'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading \(path) from \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            switch JSONPath.query(text, path: path) {
            case .badJSON: return ("'\(it.title)' doesn't parse as JSON.", [])
            case .badPath: return ("Couldn't parse the path '\(path)'. Use dot/bracket syntax like 'address.city' or 'items[0].id'.", [])
            case .notFound: return ("No value at '\(path)' in '\(it.title)' (missing key or out-of-range index). Try inspect_json to see the structure.", [])
            case .found(let value): return ("\(path) = \(value)", [])
            }

        case "text_stats":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Measuring \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = TextStats.report(text) else {
                return ("'\(it.title)' has no readable text to measure.", [])
            }
            return ("\(it.title): \(report)", [])

        case "task_progress":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Tallying tasks in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = ChecklistAnalyzer.report(text) else {
                return ("No markdown checklist items (- [ ] / - [x]) found in '\(it.title)'.", [])
            }
            return ("\(it.title) — \(report)", [])

        case "quick_summary":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Summarizing \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = ExtractiveSummary.summarize(text) else {
                return ("'\(it.title)' has no text to summarize.", [])
            }
            return ("Quick summary of '\(it.title)' (extractive, offline):\n\(summary)", [])

        case "extract_key_values":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading fields in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = KeyValueExtractor.summary(text) else {
                return ("No 'Key: Value' metadata fields found in '\(it.title)'.", [])
            }
            return ("Fields in '\(it.title)':\n\(summary)", [])

        case "redact_pii":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Redacting \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = Redactor.report(text) else {
                return ("No emails, phone numbers, or SSNs detected in '\(it.title)' — nothing to redact.", [])
            }
            return ("\(it.title) (redacted) — \(report)", [])

        case "scan_secrets":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Scanning \(it.title) for secrets…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = SecretScanner.report(text) else {
                return ("No leaked credentials detected in '\(it.title)'.", [])
            }
            return ("\(it.title) — \(report)", [])

        case "key_phrases":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding key phrases in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = PhraseExtractor.summary(text) else {
                return ("No recurring multi-word phrases found in '\(it.title)' — try keyword_extract for single terms.", [])
            }
            return ("'\(it.title)' — \(summary)", [])

        case "extract_amounts":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Totalling amounts in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = MoneyExtractor.summary(text) else {
                return ("No monetary amounts found in '\(it.title)'.", [])
            }
            return ("'\(it.title)' — \(summary)", [])

        case "extract_definitions":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding definitions in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = DefinitionExtractor.summary(text) else {
                return ("No definition sentences found in '\(it.title)'.", [])
            }
            return ("Glossary from '\(it.title)':\n\(summary)", [])

        case "extract_mentions":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding tags & mentions in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = HashtagExtractor.summary(text) else {
                return ("No #hashtags or @mentions found in '\(it.title)'.", [])
            }
            return ("'\(it.title)':\n\(summary)", [])

        case "bar_chart":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (label: value pairs).", []) }
            guard let chart = AsciiChart.render(data) else {
                return ("Couldn't parse any 'label: value' pairs from the data. Example: 'Jan: 8, Feb: 5'.", [])
            }
            return ("```\n\(chart)\n```", [])

        case "parse_url":
            guard let url = arg("url"), !url.isEmpty else { return ("Missing 'url'.", []) }
            guard let summary = URLParser.summary(url) else {
                return ("'\(url)' doesn't look like a valid URL.", [])
            }
            return ("URL parts:\n\(summary)", [])

        case "jwt_decode":
            guard let token = arg("token"), !token.isEmpty else { return ("Missing 'token'.", []) }
            guard let decoded = JWTDecoder.decode(token) else {
                return ("That doesn't look like a valid JWT (expected header.payload.signature, base64url).", [])
            }
            let header = JWTDecoder.prettify(decoded.header)
            let payload = JWTDecoder.prettify(decoded.payload)
            return ("Header:\n```json\n\(header)\n```\nPayload:\n```json\n\(payload)\n```\n_(Signature not verified.)_", [])

        case "slugify":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let slug = Slugifier.slugify(text)
            guard !slug.isEmpty else { return ("'\(text)' has no slug-able characters (try a title with letters/digits).", []) }
            return (slug, [])

        case "hash_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return ("SHA-256: \(HashUtil.sha256(text))\nShort: \(HashUtil.short(text))", [])

        case "base64":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            if (arg("mode") ?? "encode").lowercased() == "decode" {
                guard let decoded = Base64Util.decode(text) else {
                    return ("That isn't valid base64 (or the bytes aren't UTF-8 text).", [])
                }
                return (decoded, [])
            }
            return (Base64Util.encode(text), [])

        case "html_entities":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let unescape = (arg("mode") ?? "escape").lowercased() == "unescape"
            return (unescape ? HTMLEntities.unescape(text) : HTMLEntities.escape(text), [])

        case "url_encode":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            if (arg("mode") ?? "encode").lowercased() == "decode" {
                guard let decoded = URLEncoding.decode(text) else { return ("That has malformed percent-encoding.", []) }
                return (decoded, [])
            }
            return (URLEncoding.encode(text), [])

        case "caesar":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let n = Int(arg("shift") ?? "") ?? 13
            return (Caesar.shift(text, by: n), [])

        case "nato":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let spelled = NatoPhonetic.spell(text) else { return ("Nothing to spell.", []) }
            return (spelled, [])

        case "vigenere":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let key = arg("key"), !key.isEmpty else { return ("Missing 'key' (the keyword).", []) }
            let decode = (arg("mode") ?? "encode").lowercased() == "decode"
            guard let out = VigenereCipher.transform(text, key: key, decode: decode) else {
                return ("The key must contain at least one letter.", [])
            }
            return (out, [])

        case "char_frequency":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let rows = CharFrequency.analyze(text)
            guard !rows.isEmpty else { return ("No letters to analyze.", []) }
            let top = Swift.min(Swift.max(Int(arg("top") ?? "") ?? 26, 1), 26)
            return ("```\n\(CharFrequency.table(rows, limit: top))\n```", [])

        case "morse":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let mode = (arg("mode") ?? "").lowercased()
            // Auto-detect: text made only of . - / and whitespace is Morse → decode.
            let looksLikeMorse = text.allSatisfy { ".-/ \n\t".contains($0) }
            let decode = mode == "decode" || (mode != "encode" && looksLikeMorse)
            if decode {
                guard let out = MorseCode.decode(text) else { return ("Couldn't decode any Morse.", []) }
                return (out, [])
            }
            guard let out = MorseCode.encode(text) else { return ("Nothing encodable to Morse.", []) }
            return ("```\n\(out)\n```", [])

        case "make_checklist":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (a list of items).", []) }
            guard let checklist = ChecklistBuilder.build(data) else {
                return ("No items to turn into a checklist. Pass items one per line.", [])
            }
            return (checklist, [])

        case "format_list":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let style = arg("style"), let out = ListFormatter.format(text, style: style) else {
                return ("Couldn't format the list. Use style 'numbered', 'bullet', 'comma', or 'and', with items one per line.", [])
            }
            return (out, [])

        case "change_case":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let mode = arg("mode"), let result = CaseConverter.convert(text, mode: mode) else {
                return ("Unknown case mode. Use 'upper', 'lower', 'title', or 'sentence'.", [])
            }
            return (result, [])

        case "headline_case":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return (HeadlineCase.titleize(text), [])

        case "acronym":
            guard let phrase = arg("phrase"), !phrase.isEmpty else { return ("Missing 'phrase'.", []) }
            let skipMinor = (arg("skip_minor") ?? "false").lowercased() == "true"
            let acronym = AcronymMaker.make(phrase, skipMinor: skipMinor)
            guard !acronym.isEmpty else { return ("No letters to acronymize in '\(phrase)'.", []) }
            return ("\(phrase) → \(acronym)", [])

        case "case_style":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let style = arg("style"), let out = CaseStyle.convert(text, style: style), !out.isEmpty else {
                return ("Use style 'snake', 'camel', 'kebab', or 'pascal' with an identifier.", [])
            }
            return (out, [])

        case "word_frequency":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let n = Int(arg("top") ?? "") ?? 10
            guard let summary = WordFrequency.summary(text, n: n) else {
                return ("No content words found (after removing short/stop words).", [])
            }
            return (summary, [])

        case "count_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return (TextCounts.report(text), [])

        case "count_occurrences":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let needle = arg("needle"), !needle.isEmpty else { return ("Missing 'needle' (what to count).", []) }
            let cs = (arg("case_sensitive") ?? "false").lowercased() == "true"
            let ww = (arg("whole_word") ?? "false").lowercased() == "true"
            guard let n = OccurrenceCounter.count(in: text, needle: needle, caseSensitive: cs, wholeWord: ww) else {
                return ("Nothing to count.", [])
            }
            return ("'\(needle)' appears \(n) time\(n == 1 ? "" : "s")\(ww ? " (whole word)" : "")\(cs ? " (case-sensitive)" : "").", [])

        case "palindrome":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let yes = Palindrome.isPalindrome(text)
            return ("'\(text)' is \(yes ? "a palindrome" : "not a palindrome").", [])

        case "anagram":
            guard let a = arg("a"), !a.isEmpty, let b = arg("b"), !b.isEmpty else {
                return ("Need two phrases ('a' and 'b') to compare.", [])
            }
            let yes = Anagram.isAnagram(a, b)
            return ("'\(a)' and '\(b)' are \(yes ? "anagrams" : "NOT anagrams").", [])

        case "reverse":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return ((arg("mode") ?? "chars").lowercased() == "words" ? Reverse.words(text) : Reverse.chars(text), [])

        case "truncate":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let length = Int(arg("length") ?? ""), length > 0 else { return ("Need a positive 'length'.", []) }
            let byWords = (arg("mode") ?? "chars").lowercased() == "words"
            return (byWords ? Truncate.toWords(text, length) : Truncate.toChars(text, length), [])

        case "replace_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let find = arg("find"), !find.isEmpty else { return ("Missing 'find'.", []) }
            let replacement = arg("replace") ?? ""
            let ci = (arg("case_insensitive") ?? "false").lowercased() == "true"
            let (out, count) = TextReplace.replace(text, find: find, with: replacement, caseInsensitive: ci)
            guard count > 0 else { return ("No occurrences of '\(find)' found — text unchanged.", []) }
            return ("\(out)\n\n(\(count) replacement\(count == 1 ? "" : "s"))", [])

        case "extract_between":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let start = arg("start"), !start.isEmpty, let end = arg("end"), !end.isEmpty else {
                return ("Need non-empty 'start' and 'end' markers.", [])
            }
            guard let summary = TextBetween.summary(text, start: start, end: end) else {
                return ("No text found between '\(start)' and '\(end)'.", [])
            }
            return (summary, [])

        case "reindent":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            switch (arg("mode") ?? "").lowercased() {
            case "indent":
                let spaces = Int(arg("spaces") ?? "") ?? 2
                return (TextIndent.indent(text, spaces: spaces), [])
            case "dedent":
                return (TextIndent.dedent(text), [])
            default:
                return ("Set mode to 'indent' or 'dedent'.", [])
            }

        case "wrap_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let width = Int(arg("width") ?? "") ?? 80
            return (TextWrap.wrap(text, width: max(1, width)), [])

        case "word_diff":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' texts.", []) }
            return (WordDiff.summary(a, b), [])

        case "line_diff":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' texts.", []) }
            let d = LineDiff.diff(a, b)
            if d.added == 0 && d.removed == 0 { return ("No differences — the two texts are identical.", []) }
            return ("\(d.added) added, \(d.removed) removed:\n```\n\(d.lines.joined(separator: "\n"))\n```", [])

        case "fill_in":
            guard let prefix = arg("prefix"), !prefix.isEmpty else { return ("Missing 'prefix' (text before the gap).", []) }
            let suffix = arg("suffix") ?? ""
            guard let raw = try? await deepSeek.fillInMiddle(prompt: prefix, suffix: suffix, maxTokens: 512), !raw.isEmpty else {
                return ("Couldn't generate a fill-in (the model returned nothing).", [])
            }
            let middle = FillIn.trimSuffixEcho(raw, suffix: suffix)
            return ("```\n\(middle)\n```", [])

        case "deep_reason":
            guard let question = arg("question"), !question.isEmpty else { return ("Missing 'question'.", []) }
            onStatus(ReasonerRouter.rationale(question))
            guard let result = try? await deepSeek.reasonedAnswer(question), !result.answer.isEmpty else {
                return ("The reasoner returned no answer (it may be unavailable for this account).", [])
            }
            var out = result.answer
            if let reasoning = result.reasoning, !reasoning.isEmpty {
                out += "\n\n<details>\n<summary>Reasoning</summary>\n\n\(reasoning)\n\n</details>"
            }
            return (out, [])

        case "extract_fields":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let fieldsRaw = arg("fields"), !fieldsRaw.isEmpty else { return ("Missing 'fields' (comma-separated names).", []) }
            let fields = fieldsRaw.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !fields.isEmpty else { return ("No field names found in 'fields'.", []) }
            let prior = FieldExtractor.messages(text: text, fields: fields)
            // Prefer native JSON mode (response_format); fall back to the beta-prefix path.
            var json = (try? await deepSeek.completeJSONMode(prior: prior)).flatMap { $0 }
            if json == nil { json = (try? await deepSeek.completeJSON(prior: prior)).flatMap { $0 } }
            guard let json, let table = FieldExtractor.format(json: json, fields: fields) else {
                return ("Couldn't extract structured fields — the model returned no valid JSON.", [])
            }
            return ("```\n\(table)\n```", [])

        case "text_similarity":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' texts.", []) }
            let pct = Int((Similarity.jaccard(a, b) * 100).rounded())
            return ("Similarity: \(pct)% (Jaccard word overlap).", [])

        case "edit_distance":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' strings.", []) }
            let dist = Levenshtein.distance(a, b)
            let pct = Int((Levenshtein.ratio(a, b) * 100).rounded())
            return ("Edit distance: \(dist) (\(pct)% similar).", [])

        case "extract_json":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let blocks = EmbeddedJSON.candidates(text)
            guard !blocks.isEmpty else { return ("No valid JSON found in the text.", []) }
            let body = blocks.map { "```json\n\($0)\n```" }.joined(separator: "\n\n")
            return ("Found \(blocks.count) JSON block(s):\n\(body)", [])

        case "number_bases":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let described = NumberBases.describe(value) else {
                return ("'\(value)' isn't a valid integer (try decimal or 0x/0b/0o-prefixed).", [])
            }
            return (described, [])

        case "convert_base":
            guard let value = arg("value"), !value.isEmpty,
                  let from = Int(arg("from") ?? ""), let to = Int(arg("to") ?? "") else {
                return ("Need 'value' and integer 'from'/'to' bases.", [])
            }
            guard let out = BaseConvert.convert(value, from: from, to: to) else {
                return ("Couldn't convert — bases must be 2–36 and '\(value)' valid in base \(from).", [])
            }
            return ("\(value) (base \(from)) = \(out) (base \(to))", [])

        case "roman_numeral":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let out = Roman.convert(value) else {
                return ("Couldn't convert '\(value)' — use a number 1–3999 or a valid Roman numeral.", [])
            }
            return ("\(value) = \(out)", [])

        case "duration":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            if let secs = Int(value.trimmingCharacters(in: .whitespaces)) {
                return ("\(secs) seconds = \(HumanDuration.humanize(secs))", [])
            }
            guard let secs = HumanDuration.parse(value) else {
                return ("Couldn't parse '\(value)' — use seconds, '1h 30m', or '1:30:00'.", [])
            }
            return ("\(value) = \(secs) seconds (\(HumanDuration.humanize(secs)))", [])

        case "file_size":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            if let bytes = Int(value.trimmingCharacters(in: .whitespaces)) {
                return ("\(bytes) bytes = \(ByteSize.humanize(bytes))", [])
            }
            guard let bytes = ByteSize.parse(value) else {
                return ("Couldn't parse '\(value)' — use bytes or a size like '1.5 MB'.", [])
            }
            return ("\(value) = \(bytes) bytes", [])

        case "number_to_words":
            guard let value = arg("value"), let n = Int(value.trimmingCharacters(in: .whitespaces)) else {
                return ("Need an integer 'value'.", [])
            }
            guard let words = NumberWords.spell(n) else { return ("That number is too large to spell out.", []) }
            return ("\(n) = \(words)", [])

        case "number_format":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let out = NumberFormat.grouped(value) else { return ("'\(value)' isn't a number.", []) }
            return (out, [])

        case "ordinal":
            guard let value = arg("value"), let n = Int(value.trimmingCharacters(in: .whitespaces)) else {
                return ("Need an integer 'value'.", [])
            }
            return (Ordinal.format(n), [])

        case "gcd_lcm":
            guard let a = Int(arg("a") ?? ""), let b = Int(arg("b") ?? "") else { return ("Need integer 'a' and 'b'.", []) }
            return ("gcd(\(a), \(b)) = \(MathGCD.gcd(a, b)), lcm = \(MathGCD.lcm(a, b))", [])

        case "factorize":
            guard let n = Int(arg("value") ?? "") else { return ("Need an integer 'value'.", []) }
            guard n >= 2, n <= 1_000_000_000_000 else { return ("Give an integer between 2 and 1,000,000,000,000.", []) }
            if PrimeUtil.isPrime(n) { return ("\(n) is prime.", []) }
            let factors = PrimeUtil.factorize(n)
            return ("\(n) = \(factors.map(String.init).joined(separator: " × "))", [])

        case "temperature":
            guard let value = Double(arg("value") ?? ""), let from = arg("from"), let to = arg("to") else {
                return ("Need numeric 'value' and 'from'/'to' units (C, F, or K).", [])
            }
            guard let result = TempConvert.convert(value, from: from, to: to) else {
                return ("Units must be C, F, or K.", [])
            }
            return ("\(TempConvert.fmt(value))° \(from.uppercased().prefix(1)) = \(TempConvert.fmt(result))° \(to.uppercased().prefix(1))", [])

        case "color":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let out = ColorConvert.describe(value) else {
                return ("Couldn't parse '\(value)' as a color — use #RRGGBB, #RGB, or 'r,g,b' (0–255).", [])
            }
            return (out, [])

        case "luhn":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            let valid = Luhn.isValid(value)
            return ("\(value) is \(valid ? "valid" : "invalid") (Luhn checksum).", [])

        case "password_strength":
            guard let pw = arg("password"), !pw.isEmpty else { return ("Missing 'password'.", []) }
            guard let r = PasswordStrength.evaluate(pw) else { return ("Nothing to evaluate.", []) }
            return ("\(Int(r.bits.rounded())) bits of entropy — \(r.label) (\(pw.count) chars, pool \(r.poolSize)).", [])

        case "validate_email":
            guard let email = arg("email"), !email.isEmpty else { return ("Missing 'email'.", []) }
            return ("'\(email)' is \(EmailValidator.isValid(email) ? "a valid" : "not a valid") email address.", [])

        case "percentage":
            guard let mode = arg("mode"),
                  let a = Double(arg("a") ?? ""), let b = Double(arg("b") ?? "") else {
                return ("Need 'mode' and numeric 'a' and 'b'.", [])
            }
            switch mode.lowercased() {
            case "of":
                return ("\(Percentage.fmt(a))% of \(Percentage.fmt(b)) = \(Percentage.fmt(Percentage.of(a, b)))", [])
            case "what_percent":
                guard let p = Percentage.whatPercent(a, of: b) else { return ("Can't divide by zero (b is 0).", []) }
                return ("\(Percentage.fmt(a)) is \(Percentage.fmt(p))% of \(Percentage.fmt(b))", [])
            case "change":
                guard let c = Percentage.change(from: a, to: b) else { return ("Can't compute change from 0.", []) }
                let sign = c > 0 ? "+" : ""
                return ("From \(Percentage.fmt(a)) to \(Percentage.fmt(b)) is \(sign)\(Percentage.fmt(c))%", [])
            default:
                return ("Unknown mode. Use 'of', 'what_percent', or 'change'.", [])
            }

        case "format_json":
            guard let json = arg("json"), !json.isEmpty else { return ("Missing 'json'.", []) }
            let minify = (arg("mode") ?? "pretty").lowercased() == "minify"
            guard let out = minify ? JSONFormatter.minify(json) : JSONFormatter.pretty(json) else {
                return ("That isn't valid JSON (needs a top-level object or array).", [])
            }
            return ("```json\n\(out)\n```", [])

        case "json_merge":
            guard let a = arg("a"), !a.isEmpty, let b = arg("b"), !b.isEmpty else { return ("Need both 'a' and 'b' JSON objects.", []) }
            let deep = (arg("deep") ?? "true").lowercased() != "false"
            guard let merged = JSONMerge.merge(a, b, deep: deep) else {
                return ("Both 'a' and 'b' must be JSON objects ({...}).", [])
            }
            return ("```json\n\(merged)\n```", [])

        case "sort_lines":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            func flag(_ k: String) -> Bool { (arg(k) ?? "false").lowercased() == "true" }
            let sorted = LineSorter.sort(text, descending: flag("descending"),
                                         unique: flag("unique"), numeric: flag("numeric"))
            guard !sorted.isEmpty else { return ("No non-blank lines to sort.", []) }
            return (sorted, [])

        case "compare_lists":
            guard let a = arg("a"), let b = arg("b") else { return ("Missing 'a' or 'b'.", []) }
            let mode = arg("mode") ?? "common"
            guard let result = ListOps.compare(a, b, op: mode) else {
                return ("Unknown mode. Use 'common', 'only_a', 'only_b', or 'union'.", [])
            }
            guard !result.isEmpty else { return ("No items in the '\(mode)' result.", []) }
            return ("\(result.count) item(s) (\(mode)):\n" + result.map { "  \($0)" }.joined(separator: "\n"), [])

        case "strip_markdown":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let plain = MarkdownStripper.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return ("Nothing left after stripping markdown.", []) }
            return (plain, [])

        case "weekday":
            guard let date = arg("date"), !date.isEmpty else { return ("Missing 'date' (YYYY-MM-DD).", []) }
            guard let day = Weekday.of(date) else {
                return ("'\(date)' isn't a valid date — use YYYY-MM-DD.", [])
            }
            return ("\(date) is a \(day).", [])

        case "date_diff":
            guard let from = arg("from"), !from.isEmpty else { return ("Missing 'from' date (YYYY-MM-DD).", []) }
            let to = arg("to").flatMap { $0.isEmpty ? nil : $0 } ?? DateMath.todayISO(Date())
            guard let days = DateMath.daysBetween(from: from, to: to) else {
                return ("Couldn't parse the dates — use YYYY-MM-DD.", [])
            }
            return (DateMath.phrase(days, from: from, to: to), [])

        case "add_days":
            guard let date = arg("date"), !date.isEmpty else { return ("Missing 'date' (YYYY-MM-DD).", []) }
            guard let n = Int(arg("days") ?? "") else { return ("Missing or invalid 'days' (an integer).", []) }
            guard let result = DateMath.addDays(to: date, days: n) else {
                return ("Couldn't parse '\(date)' — use YYYY-MM-DD.", [])
            }
            let weekday = DateMath.weekday(result).map { " (\($0))" } ?? ""
            return ("\(date) + \(n) day\(abs(n) == 1 ? "" : "s") = \(result)\(weekday)", [])

        case "make_table":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (rows of cells).", []) }
            guard let table = MarkdownTable.make(data) else {
                return ("Couldn't build a table from the data. Pass newline-separated rows with comma- or pipe-separated cells.", [])
            }
            return (table, [])

        case "number_stats":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            guard let report = NumberStats.report(data) else {
                return ("Couldn't parse any numbers from the data. Pass values separated by commas or spaces.", [])
            }
            return (report, [])

        case "sparkline":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            guard let spark = TextSparkline.render(data) else {
                return ("Couldn't parse any numbers from the data. Pass values separated by commas or spaces.", [])
            }
            return (spark, [])

        case "quartiles":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard let q = Quartiles.compute(nums) else {
                return ("Couldn't parse any numbers from the data.", [])
            }
            let f = Quartiles.fmt
            return ("Q1 \(f(q.q1)), median \(f(q.q2)), Q3 \(f(q.q3)), IQR \(f(q.iqr)) (min \(f(nums.min()!)), max \(f(nums.max()!)))", [])

        case "z_score":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard !nums.isEmpty else { return ("Couldn't parse any numbers from the data.", []) }
            if let valueStr = arg("value"), let target = Double(valueStr) {
                guard let z = ZScore.score(of: target, in: nums) else {
                    return ("Can't compute a z-score — the numbers have zero spread (all identical).", [])
                }
                return ("z = \(Quartiles.fmt((z * 1000).rounded() / 1000)) for \(Quartiles.fmt(target)) (n=\(nums.count)).", [])
            }
            guard let zs = ZScore.standardize(nums) else {
                return ("Can't standardize — the numbers have zero spread (all identical).", [])
            }
            let list = zs.map { Quartiles.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
            return ("z-scores: \(list)", [])

        case "percentile":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            let p = Double(arg("p") ?? "") ?? 50
            guard let v = Percentile.value(nums, p: p) else {
                return ("Couldn't parse any numbers from the data.", [])
            }
            let pClamped = Swift.max(0, Swift.min(100, p))
            return ("P\(Quartiles.fmt(pClamped)) = \(Quartiles.fmt((v * 1000).rounded() / 1000)) (n=\(nums.count)).", [])

        case "histogram":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let n = Swift.min(Swift.max(Int(arg("bins") ?? "") ?? 10, 1), 50)
            guard let bins = Histogram.bins(NumberStats.parse(data), count: n) else {
                return ("Couldn't parse any numbers from the data.", [])
            }
            return ("```\n\(Histogram.chart(bins))\n```", [])

        case "outliers":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let k = Swift.max(Double(arg("k") ?? "") ?? 1.5, 0.1)
            guard let r = Outliers.detect(NumberStats.parse(data), k: k) else {
                return ("Need at least 4 numbers to detect outliers.", [])
            }
            let f = Quartiles.fmt
            let outs = r.low + r.high
            if outs.isEmpty {
                return ("No outliers (k=\(f(k)) fences \(f(r.lowerFence))…\(f(r.upperFence))).", [])
            }
            let list = outs.map(f).joined(separator: ", ")
            return ("\(outs.count) outlier\(outs.count == 1 ? "" : "s"): \(list) (outside \(f(r.lowerFence))…\(f(r.upperFence)), k=\(f(k))).", [])

        case "correlation":
            guard let xs = arg("x"), !xs.isEmpty, let ys = arg("y"), !ys.isEmpty else {
                return ("Missing 'x' and/or 'y' (two number lists).", [])
            }
            let x = NumberStats.parse(xs), y = NumberStats.parse(ys)
            guard x.count == y.count else {
                return ("x has \(x.count) numbers but y has \(y.count) — the two lists must be the same length.", [])
            }
            guard let r = Correlation.pearson(x, y) else {
                return ("Need at least 2 paired numbers, and neither list can be constant (flat).", [])
            }
            return ("r = \(Quartiles.fmt((r * 1000).rounded() / 1000)) (\(Correlation.describe(r)), n=\(x.count))", [])

        case "moving_average":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard !nums.isEmpty else { return ("Couldn't parse any numbers from the data.", []) }
            let w = Swift.max(Int(arg("window") ?? "") ?? 3, 1)
            guard let ma = MovingAverage.simple(nums, window: w) else {
                return ("Window (\(w)) must be between 1 and the number of values (\(nums.count)).", [])
            }
            let list = ma.map { Quartiles.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
            return ("\(w)-point moving average (\(ma.count) values): \(list)", [])

        case "pct_change":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard let changes = PctChange.series(nums) else {
                return ("Need at least 2 numbers to compute changes.", [])
            }
            let list = changes.map { c -> String in
                guard let c else { return "n/a" }
                let v = Quartiles.fmt((c * 100).rounded() / 100)
                return (c > 0 ? "+" : "") + v + "%"
            }.joined(separator: ", ")
            return ("Period-over-period change (\(changes.count) steps): \(list)", [])

        case "running_total":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard !nums.isEmpty else { return ("Couldn't parse any numbers from the data.", []) }
            let totals = RunningTotal.cumulative(nums)
            let list = totals.map { Quartiles.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
            return ("Running totals (\(totals.count) values): \(list) — grand total \(Quartiles.fmt((totals.last! * 100).rounded() / 100)).", [])

        case "tally":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (a list of values).", []) }
            guard let summary = Tally.summary(data) else {
                return ("Couldn't find any values to tally. Pass values one per line or comma-separated.", [])
            }
            return (summary, [])

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
