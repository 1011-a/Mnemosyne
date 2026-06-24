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
    • unicode_info(text) — code point (U+XXXX) + Unicode name of each character.
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
    • confidence_check(question) — answer + a high/moderate/low confidence score from token logprobs.
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
    • compound_interest(principal, rate, years, times_per_year) — future value with compound interest.
    • loan_payment(principal, rate, years) — monthly loan/mortgage payment + total interest.
    • tip(bill, percent, people) — tip amount, total, and per-person split.
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
            tool("unicode_info", "Inspect the Unicode code point (U+XXXX) and official name of each character in some text — useful for invisible characters, look-alikes, emoji, or accents.",
                 ["text": ["type": "string", "description": "The text whose characters to inspect."]],
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
            tool("confidence_check", "Answer a question AND report how confident the model is (from its token log-probabilities) — high/moderate/low with a percentage. Use when the user wants a reliability signal, e.g. 'how sure are you that…'.",
                 ["question": ["type": "string", "description": "The question to answer with a confidence score."]],
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
            tool("compound_interest", "Compound-interest future value — what a principal grows to at a given annual rate over some years. Set 'principal', 'rate' (annual %), 'years', and optional 'times_per_year' (compounding frequency, default 1).",
                 ["principal": ["type": "number", "description": "Starting amount."],
                  "rate": ["type": "number", "description": "Annual interest rate, as a percent (e.g. 5 for 5%)."],
                  "years": ["type": "number", "description": "Number of years."],
                  "times_per_year": ["type": "integer", "description": "Compounding periods per year (default 1; 12=monthly)."]],
                 required: ["principal", "rate", "years"]),
            tool("loan_payment", "Monthly payment on a fixed-rate loan (amortization) — e.g. a mortgage or car loan. Set 'principal', 'rate' (annual %), and 'years'. Reports the monthly payment and total interest.",
                 ["principal": ["type": "number", "description": "Loan amount."],
                  "rate": ["type": "number", "description": "Annual interest rate, as a percent (e.g. 6 for 6%)."],
                  "years": ["type": "number", "description": "Loan term in years."]],
                 required: ["principal", "rate", "years"]),
            tool("tip", "Calculate a tip and split a bill — tip amount, grand total, and per-person share. Set 'bill', 'percent' (e.g. 20), and optional 'people' (default 1).",
                 ["bill": ["type": "number", "description": "The pre-tip bill amount."],
                  "percent": ["type": "number", "description": "Tip percentage, e.g. 18."],
                  "people": ["type": "integer", "description": "Split among this many people (default 1)."]],
                 required: ["bill", "percent"]),
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
        // Long-term memory: pinned facts are ALWAYS in context, never compacted away. Build the
        // block deterministically (sorted + de-duped) so this leading prefix stays byte-stable
        // across sessions — that's what lets DeepSeek's context cache hit on it.
        if let facts = try? await store.allPinnedFacts(), !facts.isEmpty {
            let block = PromptCachePrefix.stableFactsBlock(facts.map(\.fact))
            if !block.isEmpty {
                convo.append(["role": "system",
                              "content": "PINNED FACTS the user wants you to always remember:\n\(block)"])
            }
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
    func render(_ hits: [RetrievedChunk], startingAt offset: Int) -> (String, [Citation]) {
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

        default:
            // Pure tools live in focused ToolAgent*Tools.swift files to keep this file lean.
            if let result = handleNumberTool(name, args: args) { return result }
            if let result = handleEncodingTool(name, args: args) { return result }
            if let result = handleTextTool(name, args: args) { return result }
            if let result = handleCalcTool(name, args: args) { return result }
            if let result = handleDataTool(name, args: args) { return result }
            if let result = handleFormatTool(name, args: args) { return result }
            // Store/UI-coupled domain groups also live in focused files (async).
            if let result = await handleArtifactTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleSavedSearchTool(name, args: args, citationOffset: citationOffset, onStatus: onStatus) { return result }
            if let result = await handleTranslateTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleItemDiffTool(name, args: args, citationOffset: citationOffset, onStatus: onStatus) { return result }
            if let result = await handleMemoryTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleTabularTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleExtractionTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleAnalysisTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleItemTool(name, args: args, citationOffset: citationOffset, onStatus: onStatus) { return result }
            if let result = await handleTagTool(name, args: args, onStatus: onStatus) { return result }
            if let result = await handleLibraryTool(name, args: args, citationOffset: citationOffset, onStatus: onStatus) { return result }
            if let result = await handleItemContentTool(name, args: args, citationOffset: citationOffset, onStatus: onStatus) { return result }
            if let result = await handleWebTool(name, args: args, citationOffset: citationOffset, onStatus: onStatus) { return result }
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
    /// Internal (not private) so the extracted artifact-tool handlers can reach it across files.
    static func artifactsDir(for task: String) -> String {
        let base = NSHomeDirectory() + "/Documents/Mnemosyne Artifacts"
        let slug = String(task.lowercased().prefix(40)).map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let cleaned = String(String(slug).split(separator: "-").joined(separator: "-").prefix(40))
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(base)/\(stamp)-\(cleaned.isEmpty ? "artifact" : cleaned)"
    }

    /// Resolve a file reference (title or distinctive substring) to matching items —
    /// exact title first, otherwise a case-insensitive substring match.
    func resolveItems(_ ref: String) async -> [KnowledgeItem] {
        let items = (try? await store.allItems()) ?? []
        let r = ref.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = items.filter { $0.title.lowercased() == r }
        return exact.isEmpty ? items.filter { $0.title.lowercased().contains(r) } : exact
    }

    static func ambiguity(_ matches: [KnowledgeItem], ref: String) -> String {
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
