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

    /// Appended just before the final answer so the model leaves tool-calling mode and
    /// writes prose. Without it, deepseek-chat — handed a tool-heavy transcript (and often
    /// stopped mid-gather at the step limit) with `tool_choice:none` but no other steer —
    /// keeps trying to call tools; with no tool channel open those calls spill into the
    /// answer as literal `<invoke>/<parameter>/<tool_calls>` markup.
    static let finalAnswerDirective = """
    You now have all the information you're going to get. STOP using tools: do not emit any \
    tool call or function-call markup of any kind — no <tool_calls>, <invoke>, <parameter>, \
    or function-call JSON. Write your COMPLETE final answer to the user as plain prose \
    (Markdown is fine), grounded in the evidence above and citing sources by their [n] markers. \
    If you couldn't finish everything, say so in one short sentence and answer with what you have.
    """

    /// Longest leaked-markup opening tag we recognise (with a namespace prefix like `antml:`),
    /// in characters — the streaming guard holds back this many trailing chars so a tag split
    /// across token boundaries can't slip out before it's recognised.
    static let leakedToolMarkupHoldback = 24

    /// Earliest index where leaked tool-call / function-call markup begins, or nil if the text is
    /// clean. Tolerates any namespace prefix (e.g. `antml:`).
    static func leakedToolMarkupStart(_ text: String) -> String.Index? {
        let openings = [#"<[A-Za-z_]*:?function_calls\b"#, #"<[A-Za-z_]*:?invoke\b"#,
                        #"<[A-Za-z_]*:?tool_calls\b"#, #"<[A-Za-z_]*:?parameter\b"#]
        var cut: String.Index? = nil
        for pat in openings {
            if let r = text.range(of: pat, options: [.regularExpression, .caseInsensitive]),
               cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
        }
        return cut
    }

    /// Defense-in-depth for the final answer: if the model still leaks tool-call / function-call
    /// markup into its prose (despite tool_choice:none + the directive), cut from the first leaked
    /// opening tag onward — a leak means it abandoned prose, so nothing after it is usable. Pure +
    /// deterministic → unit-testable.
    static func stripLeakedToolMarkup(_ text: String) -> String {
        let cut = leakedToolMarkupStart(text) ?? text.endIndex
        return String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        var c = convo
        c.append(["role": "system", "content": Self.finalAnswerDirective])
        return ["model": deepSeek.config.deepSeekModel, "messages": c,
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
        let text = Self.stripLeakedToolMarkup(resp.choices.first?.message.content ?? "")
        return Answer(text: text, citations: phase.citations, searches: phase.searches)
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
                    // Guard the answer stream: hold back a short trailing buffer so a leaked tool-call
                    // tag split across tokens is caught before it reaches the UI; if a leak appears,
                    // emit the clean prefix and stop (mirrors stripLeakedToolMarkup for the non-streamed
                    // path). Only `.answer` text is scrubbed — `.reasoning` (the thinking trace) passes
                    // through untouched. Offsets are character counts (stable across `acc` mutations,
                    // unlike String.Index); indices are recomputed fresh on the current `acc`.
                    var acc = ""
                    var emitted = 0
                    var leaked = false
                    func emitAnswer(_ lo: Int, _ hi: Int) {
                        guard hi > lo else { return }
                        let a = acc.index(acc.startIndex, offsetBy: lo)
                        let b = acc.index(acc.startIndex, offsetBy: hi)
                        continuation.yield(.answer(String(acc[a..<b])))
                    }
                    for try await delta in deepSeek.rawStream(body: body) {
                        if Task.isCancelled { break }
                        switch delta {
                        case .reasoning:
                            continuation.yield(delta)
                        case .answer(let chunk):
                            acc += chunk
                            if let cutIdx = Self.leakedToolMarkupStart(acc) {
                                emitAnswer(emitted, acc.distance(from: acc.startIndex, to: cutIdx))
                                emitted = acc.count
                                leaked = true
                            } else {
                                let safe = Swift.max(emitted, acc.count - Self.leakedToolMarkupHoldback)
                                emitAnswer(emitted, safe)
                                emitted = Swift.max(emitted, safe)
                            }
                        }
                        if leaked { break }
                    }
                    // Flush the held-back tail. No leak survived the loop (every chunk re-scanned the
                    // full answer), so the tail is clean prose — yield it raw, without trimming, so a
                    // space straddling the holdback boundary isn't lost.
                    if !leaked, !Task.isCancelled { emitAnswer(emitted, acc.count) }
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
        // handleTool is a pure dispatcher: every tool group lives in a focused
        // ToolAgent*Tools.swift file. Pure value-in/value-out tools first (sync), then
        // store/UI/network-coupled domain groups (async). First non-nil match wins.
        if let result = handleNumberTool(name, args: args) { return result }
        if let result = handleEncodingTool(name, args: args) { return result }
        if let result = handleTextTool(name, args: args) { return result }
        if let result = handleCalcTool(name, args: args) { return result }
        if let result = handleDataTool(name, args: args) { return result }
        if let result = handleFormatTool(name, args: args) { return result }
        if let result = await handleCoreTool(name, args: args, fallbackQuery: fallbackQuery, citationOffset: citationOffset, onStatus: onStatus) { return result }
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
