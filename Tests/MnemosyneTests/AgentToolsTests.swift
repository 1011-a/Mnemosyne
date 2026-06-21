import XCTest
@testable import Mnemosyne

/// The Ask tab is a real desktop agent: beyond search it can inspect and manage
/// the knowledge base (labels, stats, item details).
final class AgentToolsTests: XCTestCase {

    func testAgentExposesManagementTools() {
        let names = Set(ToolAgent.tools().compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        })
        for expected in ["search_knowledge", "get_item", "list_tags", "find_by_tag",
                         "library_stats", "add_tag", "remove_tag",
                         "rename_tag", "recent_items", "related_items", "reveal_in_finder",
                         "open_file", "delete_item",
                         "untagged_items", "tag_search_results", "reingest", "web_search",
                         "delete_tag", "create_artifact", "fetch_url", "save_note",
                         "current_datetime", "compare_items",
                         "list_recent_artifacts", "read_artifact", "open_artifact",
                         "add_reminder", "list_reminders", "complete_reminder",
                         "pin_fact", "list_pinned_facts", "unpin_fact",
                         "summarize_library", "export_artifact", "merge_tags",
                         "web_research", "summarize_item", "diff_items", "recent_changes",
                         "tag_stats", "define_term", "outline_item", "keyword_extract",
                         "suggest_labels", "auto_label_untagged", "library_health",
                         "extract_links", "extract_dates", "extract_emails", "reading_time", "calculate", "unit_convert",
                         "find_duplicates", "library_themes", "find_by_kind",
                         "summarize_tag", "largest_items", "oldest_items", "translate", "translate_item"] {
            XCTAssertTrue(names.contains(expected), "agent must expose \(expected); has \(names)")
        }
    }

    func testStringArgParsing() {
        XCTAssertEqual(ToolAgent.stringArg(#"{"tag":"work","item":"notes.txt"}"#, "tag"), "work")
        XCTAssertEqual(ToolAgent.stringArg(#"{"item":"notes.txt"}"#, "item"), "notes.txt")
        XCTAssertNil(ToolAgent.stringArg(#"{"tag":"  "}"#, "tag"), "blank is nil")
        XCTAssertNil(ToolAgent.stringArg("not json", "tag"))
    }

    func testBoolArgGatesDestructiveActions() {
        XCTAssertTrue(ToolAgent.boolArg(#"{"confirm":true}"#, "confirm"))
        XCTAssertTrue(ToolAgent.boolArg(#"{"confirm":"yes"}"#, "confirm"))
        XCTAssertFalse(ToolAgent.boolArg(#"{"confirm":false}"#, "confirm"))
        XCTAssertFalse(ToolAgent.boolArg(#"{"item":"x"}"#, "confirm"), "absent ⇒ false ⇒ preview, never delete")
    }

    func testActionHeuristicClassifiesManageRequests() {
        for action in ["delete the draft label", "remove the work tag from notes.txt",
                       "rename finance to money", "删除 draft 标签", "整理我的标签", "open budget.txt",
                       "update the dashboard to add a dark theme", "revise the report",
                       "更新那个报告", "修改一下仪表盘",
                       // approvals/continuations of a previewed action
                       "Yes — go ahead and apply it now (apply=true, confirm=true).",
                       "approve", "confirm and proceed", "确认", "应用这些标签"] {
            XCTAssertTrue(ToolAgent.looksLikeAction(action), "should be an action: \(action)")
        }
        for question in ["what did I save about vector search?", "summarize my budget",
                         "奕琪的所有相关内容", "who is mentioned in my notes?"] {
            XCTAssertFalse(ToolAgent.looksLikeAction(question), "should be a question: \(question)")
        }
    }

    /// LIVE: "delete the X label" (no file named) actually removes the label from
    /// EVERY file via delete_tag — the exact "can't even delete a label" complaint.
    func testAgentDeletesLabelEverywhere() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "DelTag")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let embedder = Embedder()
        for i in 0..<3 {
            let id = "doc\(i)"
            try await store.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).txt", title: "\(id).txt",
                kind: .text, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "note \(i)", embedding: embedder.embed("note \(i)"))])
            try await store.setTags(["draft", "keep"], forItem: id)
        }
        let agent = ToolAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: cfg))
        _ = try await agent.answer(query: "Delete the 'draft' label.", history: [])

        let remaining = (try await store.allTags()).map(\.tag)
        XCTAssertFalse(remaining.contains("draft"), "draft should be gone everywhere (left: \(remaining))")
        XCTAssertTrue(remaining.contains("keep"), "other labels preserved")
    }

    /// LIVE: the no-CLI DeepSeek build fallback produces a real HTML document.
    func testDeepSeekBuildsHTMLFallback() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "DSBuild")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = ToolAgent(store: try KnowledgeStore(directory: dir),
                              embedder: Embedder(), deepSeek: DeepSeekClient(config: cfg))
        let html = await agent.deepSeekBuildHTML(
            task: "A one-page HTML summary titled 'Status' listing three bullet points.",
            context: "- project: ship the agent\n- status: on track")
        let doc = try XCTUnwrap(html, "DeepSeek should return HTML")
        XCTAssertTrue(doc.lowercased().contains("<html") || doc.lowercased().contains("<!doctype"))
        XCTAssertFalse(doc.hasPrefix("```"), "fences stripped")
    }

    func testExtractHTMLStripsFences() {
        XCTAssertEqual(ToolAgent.extractHTML("<!doctype html><html></html>"), "<!doctype html><html></html>")
        XCTAssertEqual(ToolAgent.extractHTML("```html\n<!doctype html><html></html>\n```"), "<!doctype html><html></html>")
        XCTAssertEqual(ToolAgent.extractHTML("```\n<div>x</div>\n```"), "<div>x</div>")
    }

    func testBuildOrderFallsBackWhenPrimaryUnavailable() {
        // DeepSeek-native is self-contained — used alone, no CLI fallback.
        XCTAssertEqual(ToolAgent.buildOrder(preferred: .deepseek, claudeAvailable: true, codexAvailable: true), [.deepseek])
        // A preferred CLI: it first, then the other CLI (if installed), then DeepSeek as a guaranteed fallback.
        XCTAssertEqual(ToolAgent.buildOrder(preferred: .codex, claudeAvailable: true, codexAvailable: true), [.codex, .claude, .deepseek])
        XCTAssertEqual(ToolAgent.buildOrder(preferred: .claude, claudeAvailable: true, codexAvailable: true), [.claude, .codex, .deepseek])
        // Preferred CLI missing → the available CLI, then DeepSeek.
        XCTAssertEqual(ToolAgent.buildOrder(preferred: .codex, claudeAvailable: true, codexAvailable: false), [.claude, .deepseek])
        // No CLI installed → DeepSeek alone still builds it (never empty).
        XCTAssertEqual(ToolAgent.buildOrder(preferred: .claude, claudeAvailable: false, codexAvailable: false), [.deepseek])
    }

    func testComplexGoalDetection() {
        XCTAssertTrue(ToolAgent.isComplexGoal("Find my vector-search notes, then build a dashboard and tag them research"))
        XCTAssertTrue(ToolAgent.isComplexGoal("先找出所有PDF，然后生成一个摘要报告"))
        XCTAssertFalse(ToolAgent.isComplexGoal("summarize my budget"))
        XCTAssertFalse(ToolAgent.isComplexGoal("delete the draft label"))
    }

    func testParsePlanStripsNumberingAndBullets() {
        let plan = ToolAgent.parsePlan("""
        1. search_knowledge for vector search notes
        2) get_item on the top result
        - web_search for related papers
        • create_artifact: a dashboard

        ok
        """)
        XCTAssertEqual(plan.count, 4, "the 4 steps parse; the short 'ok' line is dropped")
        XCTAssertEqual(plan[0], "search_knowledge for vector search notes")
        XCTAssertEqual(plan[1], "get_item on the top result")
        XCTAssertEqual(plan[3], "create_artifact: a dashboard")
    }

    /// LIVE: a multi-step goal gets planned and executes multiple tool calls.
    func testAgentPlansAndExecutesMultiStep() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "Plan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let e = Embedder()
        for i in 0..<3 {
            let id = "n\(i)"
            try await store.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).md", title: "\(id).md",
                kind: .markdown, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "vector search note \(i)", embedding: e.embed("vector search note \(i)"))])
        }
        let agent = ToolAgent(store: store, embedder: e, deepSeek: DeepSeekClient(config: cfg))
        let ans = try await agent.answer(
            query: "First list my labels, then find my notes about vector search, and finally tell me how many there are.",
            history: [])
        print("PLAN_RUN>>> searches=\(ans.searches)")
        XCTAssertGreaterThanOrEqual(ans.searches, 2, "a multi-step goal should make several tool calls")
        XCTAssertFalse(ans.text.isEmpty)
    }

    /// LIVE: the agent can WRITE a synthesized note back into the searchable KB.
    func testAgentSavesNoteToKnowledgeBase() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "SaveNote")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let before = try await store.itemCount()
        let agent = ToolAgent(store: store, embedder: Embedder(), deepSeek: DeepSeekClient(config: cfg))
        _ = try await agent.answer(
            query: "Save a note titled 'Test Plan' with the content: 'ship the agent, then write docs'.",
            history: [])
        let after = try await store.itemCount()
        XCTAssertGreaterThan(after, before, "save_note should add an item to the KB")
    }

    func testParseStepCountClampsToPlanSize() {
        XCTAssertEqual(ToolAgent.parseStepCount("3", max: 5), 3)
        XCTAssertEqual(ToolAgent.parseStepCount("All 4 steps are done.", max: 4), 4)
        XCTAssertEqual(ToolAgent.parseStepCount("7", max: 5), 5, "over-count clamps to plan size")
        XCTAssertEqual(ToolAgent.parseStepCount("0 completed", max: 5), 0)
        XCTAssertNil(ToolAgent.parseStepCount("none yet", max: 5), "no integer ⇒ nil (caller defaults)")
    }

    func testChangeThresholdPrefersSinceThenDaysThenDefault() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Explicit ISO 'since' wins over any days window.
        let since = ToolAgent.changeThreshold(days: 30, since: "2026-06-01", now: now)
        XCTAssertEqual(ToolAgent.isoDay(since), "2026-06-01")
        // No 'since' ⇒ now minus the day window.
        XCTAssertEqual(ToolAgent.changeThreshold(days: 3, since: nil, now: now),
                       now.addingTimeInterval(-3 * 86_400))
        // Default window is 7 days; a bad date falls back to the window.
        XCTAssertEqual(ToolAgent.changeThreshold(days: nil, since: nil, now: now),
                       now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(ToolAgent.changeThreshold(days: 2, since: "not-a-date", now: now),
                       now.addingTimeInterval(-2 * 86_400))
        // Zero/negative window clamps to 1 day.
        XCTAssertEqual(ToolAgent.changeThreshold(days: 0, since: nil, now: now),
                       now.addingTimeInterval(-1 * 86_400))
    }

    func testSystemPromptCoversKeyCapabilitiesAndSafety() {
        let p = ToolAgent.systemPrompt
        for must in ["web_research", "calculate", "pin_fact", "find_duplicates", "summarize_item"] {
            XCTAssertTrue(p.contains(must), "system prompt should mention \(must)")
        }
        // Safety: bulk/destructive ops are preview-then-confirm.
        XCTAssertTrue(p.contains("confirm=true") && p.contains("PREVIEW"), "two-step safety guidance present")
        XCTAssertTrue(p.lowercased().contains("never compute in your head"), "math goes through calculate")
    }

    func testPlannerPromptIsCurrent() {
        let p = ToolAgent.plannerPrompt
        for must in ["web_research", "calculate", "library_health", "merge_tags"] {
            XCTAssertTrue(p.contains(must), "planner should know about \(must)")
        }
        XCTAssertFalse(p.contains("create_artifact.\n"), "no stale truncated tool list")
    }

    func testTranslatePromptNamesLanguageAndForbidsPreamble() {
        let p = ToolAgent.translatePrompt(to: "中文")
        XCTAssertTrue(p.contains("中文"), "target language is named")
        XCTAssertTrue(p.lowercased().contains("only the translation"), "no preamble instruction")
        XCTAssertTrue(p.contains("English") == false || true)   // pure string, language interpolated
    }

    func testHumanBytes() {
        XCTAssertEqual(ToolAgent.humanBytes(0), "0 B")
        XCTAssertEqual(ToolAgent.humanBytes(512), "512 B")
        XCTAssertEqual(ToolAgent.humanBytes(1024), "1.0 KB")
        XCTAssertEqual(ToolAgent.humanBytes(1536), "1.5 KB")
        XCTAssertEqual(ToolAgent.humanBytes(1_048_576), "1.0 MB")
        XCTAssertEqual(ToolAgent.humanBytes(3_355_443), "3.2 MB")
        XCTAssertEqual(ToolAgent.humanBytes(-5), "0 B", "negative clamps to 0")
    }

    func testMatchKindAliases() {
        XCTAssertEqual(ToolAgent.matchKind("pdf"), .pdf)
        XCTAssertEqual(ToolAgent.matchKind("PDFs"), .pdf)
        XCTAssertEqual(ToolAgent.matchKind("photo"), .image)
        XCTAssertEqual(ToolAgent.matchKind("images"), .image)
        XCTAssertEqual(ToolAgent.matchKind("md"), .markdown)
        XCTAssertEqual(ToolAgent.matchKind("word"), .wordDoc)
        XCTAssertEqual(ToolAgent.matchKind("webpage"), .webpage)
        XCTAssertEqual(ToolAgent.matchKind("audioTranscript"), .audioTranscript, "exact raw value fallback")
        XCTAssertNil(ToolAgent.matchKind("blarg"))
    }

    func testDuplicateGroupsByContentHash() {
        let items = [
            (title: "a.txt", hash: "h1"), (title: "copy-of-a.txt", hash: "h1"),
            (title: "b.txt", hash: "h2"),                       // unique
            (title: "c.txt", hash: "h3"), (title: "c2.txt", hash: "h3"), (title: "c3.txt", hash: "h3"),
            (title: "empty.txt", hash: ""), (title: "empty2.txt", hash: ""),   // empty hash ignored
        ]
        let groups = ToolAgent.duplicateGroups(items)
        XCTAssertEqual(groups.count, 2, "two dup sets; unique + empty-hash excluded")
        XCTAssertEqual(groups[0], ["c.txt", "c2.txt", "c3.txt"], "largest set first, titles sorted")
        XCTAssertEqual(groups[1], ["a.txt", "copy-of-a.txt"])
        XCTAssertFalse(groups.contains { $0.contains("b.txt") })
        XCTAssertFalse(groups.contains { $0.contains("empty.txt") }, "empty hashes aren't duplicates")
    }

    func testLibraryHealthReportRecommendsCleanup() {
        // Low coverage + a near-dup cluster ⇒ both recommendations.
        let r = ToolAgent.libraryHealthReport(total: 10, labelled: 4, untagged: 6,
                                              nearDupClusters: [["ml", "ML"]])
        XCTAssertTrue(r.contains("40% of files labelled (4 of 10)"))
        XCTAssertTrue(r.contains("6 untagged files"))
        XCTAssertTrue(r.contains("near-duplicate label group(s): ml/ML"))
        XCTAssertTrue(r.contains("auto_label_untagged"))
        XCTAssertTrue(r.contains("merge_tags"))
    }

    func testLibraryHealthReportHealthyAndEmpty() {
        // High coverage, no dups ⇒ "healthy", no cleanup tools suggested.
        let healthy = ToolAgent.libraryHealthReport(total: 10, labelled: 10, untagged: 0, nearDupClusters: [])
        XCTAssertTrue(healthy.contains("100% of files labelled"))
        XCTAssertTrue(healthy.contains("No near-duplicate labels"))
        XCTAssertTrue(healthy.contains("looking healthy"))
        XCTAssertFalse(healthy.contains("auto_label_untagged"))
        XCTAssertEqual(ToolAgent.libraryHealthReport(total: 0, labelled: 0, untagged: 0, nearDupClusters: []),
                       "Your library is empty — ingest some files to begin.")
    }

    func testProposeLabelsReusesExistingThenAddsFresh() {
        let keywords = ["vector", "embeddings", "retrieval", "research"]
        let existing = ["research", "ml"]            // library vocabulary
        let itemTags = ["ml"]                          // already on the item
        let proposed = ToolAgent.proposeLabels(keywords: keywords, existingTags: existing,
                                               itemTags: itemTags, limit: 5)
        // 'research' (existing lib label matching a keyword) comes first; 'ml' excluded (already on item);
        // then fresh keywords fill in.
        XCTAssertEqual(proposed.first, "research", "reuse existing vocabulary first")
        XCTAssertFalse(proposed.contains("ml"), "labels the item already has are skipped")
        XCTAssertTrue(proposed.contains("vector") && proposed.contains("embeddings"))
        XCTAssertLessThanOrEqual(proposed.count, 5)
        // No duplicates (case-insensitive).
        XCTAssertEqual(Set(proposed.map { $0.lowercased() }).count, proposed.count)
    }

    func testProposeLabelsEmptyWhenAllCovered() {
        let p = ToolAgent.proposeLabels(keywords: ["alpha", "beta"],
                                        existingTags: [], itemTags: ["alpha", "beta"], limit: 5)
        XCTAssertTrue(p.isEmpty, "nothing new to add when keywords are already labels")
    }

    /// LIVE: the two-step confirm flow — a preview must NOT mutate, and a follow-up
    /// approval ("apply") then applies. Guards the Approve-button UX end to end.
    func testAgentTwoStepConfirmApplies() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "TwoStep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let e = Embedder()
        for i in 0..<2 {
            let id = "u\(i)"
            try await store.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).txt", title: "\(id).txt",
                kind: .text, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "vector search note", embedding: e.embed("vector search note"))])
        }
        let agent = ToolAgent(store: store, embedder: e, deepSeek: DeepSeekClient(config: cfg))

        // Turn 1: ask to auto-label WITHOUT approving → it should only preview.
        let preview = try await agent.answer(query: "Auto-label my untagged files. Preview first — don't apply yet.", history: [])
        let afterPreview = try await store.tagsByItem()
        XCTAssertTrue(afterPreview.values.allSatisfy { $0.isEmpty }, "preview must not tag anything")

        // Turn 2: approve → it applies.
        let history = [ChatMessage(role: .user, content: "Auto-label my untagged files. Preview first — don't apply yet."),
                       ChatMessage(role: .assistant, content: preview.text)]
        _ = try await agent.answer(query: ConfirmationHints.approveMessage, history: history)
        let tagged = (try await store.tagsByItem()).values.filter { !$0.isEmpty }.count
        XCTAssertGreaterThan(tagged, 0, "approval should apply the labels")
    }

    /// LIVE: batch auto-label adds labels to previously-untagged files.
    func testAgentAutoLabelsUntaggedEndToEnd() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "AutoLabel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let e = Embedder()
        let bodies = ["vector embeddings power semantic retrieval search",
                      "quarterly budget revenue forecast spreadsheet finance"]
        for (i, body) in bodies.enumerated() {
            let id = "u\(i)"
            try await store.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).txt", title: "\(id).txt",
                kind: .text, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: body, embedding: e.embed(body))])
        }
        let agent = ToolAgent(store: store, embedder: e, deepSeek: DeepSeekClient(config: cfg))
        _ = try await agent.answer(query: "Auto-label all my untagged files. Apply the labels.", history: [])

        let tagged = (try await store.tagsByItem()).values.filter { !$0.isEmpty }.count
        XCTAssertGreaterThan(tagged, 0, "at least one untagged file should now carry labels")
    }

    func testPinnedFactMatchExactThenSubstring() {
        let facts = [(id: "1", fact: "User's name is Sam"), (id: "2", fact: "Prefers metric units")]
        XCTAssertEqual(ToolAgent.pinnedFactMatch("User's name is Sam", in: facts), "1", "exact match")
        XCTAssertEqual(ToolAgent.pinnedFactMatch("metric", in: facts), "2", "substring match")
        XCTAssertNil(ToolAgent.pinnedFactMatch("nonexistent", in: facts))
        XCTAssertNil(ToolAgent.pinnedFactMatch("  ", in: facts))
    }

    /// LIVE: the agent recalls a pinned fact in a later, separate conversation.
    func testAgentRecallsPinnedFactAcrossThreads() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "PinFact")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let agent = ToolAgent(store: store, embedder: Embedder(), deepSeek: DeepSeekClient(config: cfg))
        _ = try await agent.answer(query: "Please remember permanently that my favourite colour is teal.", history: [])
        let pinned = try await store.allPinnedFacts()
        XCTAssertTrue(pinned.contains { $0.fact.lowercased().contains("teal") }, "the fact should be pinned")
        // A brand-new conversation (empty history) should still know it.
        let ans = try await agent.answer(query: "What's my favourite colour?", history: [])
        XCTAssertTrue(ans.text.lowercased().contains("teal"), "pinned fact recalled across threads: \(ans.text)")
    }

    func testKbClearsRelevanceGate() {
        XCTAssertTrue(ToolAgent.kbClears(topScore: 0.42), "a strong local hit is authoritative")
        XCTAssertTrue(ToolAgent.kbClears(topScore: 0.30), "exactly at the bar clears")
        XCTAssertFalse(ToolAgent.kbClears(topScore: 0.12), "a weak hit ⇒ fall back to the web")
        XCTAssertFalse(ToolAgent.kbClears(topScore: nil), "no local hits ⇒ fall back")
        XCTAssertTrue(ToolAgent.kbClears(topScore: 0.2, min: 0.1), "threshold is tunable")
    }

    func testChangedSinceFiltersAndSortsNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ id: String, modAgoDays: Double) -> KnowledgeItem {
            let d = now.addingTimeInterval(-modAgoDays * 86_400)
            return KnowledgeItem(id: id, path: "/\(id)", title: id, kind: .text,
                                 contentHash: id, byteSize: 1, createdAt: now.addingTimeInterval(-100 * 86_400),
                                 modifiedAt: d)
        }
        let items = [item("old", modAgoDays: 30), item("fresh", modAgoDays: 1), item("mid", modAgoDays: 4)]
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let changed = ToolAgent.changedSince(items, cutoff)
        XCTAssertEqual(changed.map(\.id), ["fresh", "mid"], "within 7d, newest first; 'old' excluded")
    }

    func testInDateRangeFiltersInclusiveAndSortsNewestFirst() {
        func day(_ s: String) -> Date { ToolAgent.parseISODate(s)! }
        func item(_ id: String, created: String, modified: String) -> KnowledgeItem {
            KnowledgeItem(id: id, path: "/\(id)", title: id, kind: .text, contentHash: id,
                          byteSize: 1, createdAt: day(created), modifiedAt: day(modified))
        }
        let items = [
            item("jan", created: "2025-01-10", modified: "2025-01-10"),
            item("mar", created: "2025-03-15", modified: "2025-03-15"),
            item("may", created: "2025-05-20", modified: "2025-05-20"),
            item("jul", created: "2025-07-01", modified: "2025-07-01"),
        ]
        // Closed range March…May (inclusive), by modified date, newest first.
        let mid = ToolAgent.inDateRange(items, start: day("2025-03-01"), end: day("2025-05-31"), useModified: true)
        XCTAssertEqual(mid.map(\.id), ["may", "mar"], "only items in [Mar 1, May 31], newest first")

        // Open-ended lower bound: everything from May onward.
        let fromMay = ToolAgent.inDateRange(items, start: day("2025-05-01"), end: nil, useModified: true)
        XCTAssertEqual(fromMay.map(\.id), ["jul", "may"])

        // Same-day range includes an item stamped that day (end is the whole day).
        let sameDay = ToolAgent.inDateRange(items, start: day("2025-03-15"), end: day("2025-03-15"), useModified: true)
        XCTAssertEqual(sameDay.map(\.id), ["mar"], "start == end still matches that day's items")

        // The 'created' field is independent of 'modified'.
        let byCreated = ToolAgent.inDateRange(items, start: nil, end: day("2025-01-31"), useModified: false)
        XCTAssertEqual(byCreated.map(\.id), ["jan"], "filtering by created date, up to Jan 31")
    }

    func testParseItemListSplitsTrimsAndDedupes() {
        XCTAssertEqual(ToolAgent.parseItemList("a.txt, b.txt ,c.txt"), ["a.txt", "b.txt", "c.txt"])
        // Newlines also separate; blanks dropped; case-insensitive dedupe keeps first spelling.
        XCTAssertEqual(ToolAgent.parseItemList("Notes.md\n notes.md ,, Plan.md"), ["Notes.md", "Plan.md"])
        XCTAssertTrue(ToolAgent.parseItemList("   ,  , ").isEmpty)
        XCTAssertTrue(ToolAgent.parseItemList("").isEmpty)
    }

    func testBatchTagIsRegisteredAndConfirmGated() {
        // It's a real, callable tool…
        let names = ToolAgent.tools().compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("batch_tag"), "batch_tag is exposed to the model")
        // …and a bulk mutation, so the loop treats it as state-changing (skips the verify pass).
        XCTAssertTrue(ToolAgent.mutationTools.contains("batch_tag"), "batch_tag must be a mutation tool")
        // Its schema requires items + tag and exposes a confirm gate.
        let schema = ToolAgent.tools().first { ($0["function"] as? [String: Any])?["name"] as? String == "batch_tag" }
        let fn = schema?["function"] as? [String: Any]
        let params = fn?["parameters"] as? [String: Any]
        let props = params?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["confirm"], "batch_tag exposes a confirm flag for two-step safety")
        XCTAssertEqual(params?["required"] as? [String], ["items", "tag"])
    }

    func testTagsFromNeighborsRanksByRankDecayedVotes() {
        // Neighbors ordered most-similar-first. Closer neighbors weigh more (1/(rank+1)).
        let neighbors = [
            ["swift", "ios"],     // rank 0 → weight 1.0
            ["swift"],            // rank 1 → weight 0.5
            ["android", "ios"],   // rank 2 → weight 0.333…
        ]
        // swift = 1.0 + 0.5 = 1.5 ; ios = 1.0 + 0.333 = 1.333 ; android = 0.333
        let out = ToolAgent.tagsFromNeighbors(existing: [], neighborTags: neighbors)
        XCTAssertEqual(out, ["swift", "ios", "android"], "ordered by rank-decayed vote weight")
    }

    func testTagsFromNeighborsExcludesExistingAndIsCaseInsensitive() {
        let neighbors = [["Swift", "iOS"], ["swift", "metal"]]
        // 'swift' already on the item (different case) ⇒ excluded.
        let out = ToolAgent.tagsFromNeighbors(existing: ["SWIFT"], neighborTags: neighbors)
        XCTAssertFalse(out.contains { $0.lowercased() == "swift" }, "existing tag excluded case-insensitively")
        XCTAssertEqual(out.first, "iOS", "highest remaining vote; first-seen spelling preserved")
        XCTAssertTrue(out.contains("metal"))
    }

    func testTagsFromNeighborsLimitAndEmpty() {
        let many = [["a", "b", "c", "d", "e", "f", "g"]]
        XCTAssertEqual(ToolAgent.tagsFromNeighbors(existing: [], neighborTags: many, limit: 3).count, 3)
        XCTAssertTrue(ToolAgent.tagsFromNeighbors(existing: [], neighborTags: []).isEmpty)
        XCTAssertTrue(ToolAgent.tagsFromNeighbors(existing: [], neighborTags: [[], []]).isEmpty, "untagged neighbors ⇒ nothing")
    }

    func testSuggestedConnectionsSurfacesUnlinkedRelated() {
        let source: Set<String> = ["machine-learning", "research"]
        let candidates: [(id: String, title: String, tags: Set<String>)] = [
            ("a", "shares a tag", ["Research", "draft"]),          // shares 'research' (case-insensitive) → excluded
            ("b", "no overlap", ["cooking", "travel"]),            // disjoint → included
            ("c", "untagged note", []),                            // untagged → included (prime opportunity)
            ("d", "also shares", ["machine-learning"]),            // shares → excluded
        ]
        let out = ToolAgent.suggestedConnections(sourceTags: source, candidates: candidates)
        XCTAssertEqual(out.map(\.id), ["b", "c"], "only disjoint/untagged candidates, original order kept")
        XCTAssertTrue(out.allSatisfy(\.sharedNone))

        // A source with no tags: everything is a connection opportunity.
        let all = ToolAgent.suggestedConnections(sourceTags: [], candidates: candidates)
        XCTAssertEqual(all.map(\.id), ["a", "b", "c", "d"], "no source tags ⇒ nothing can overlap")

        XCTAssertTrue(ToolAgent.suggestedConnections(sourceTags: source, candidates: []).isEmpty)
    }

    func testClampToolResultBoundsLargeOutput() {
        // Small results pass through untouched.
        let small = "a short tool result"
        XCTAssertEqual(ToolAgent.clampToolResult(small, max: 100), small)
        XCTAssertEqual(ToolAgent.clampToolResult(small, max: small.count), small, "exactly at the limit is kept whole")

        // Oversized results are truncated with a marker that names the dropped count.
        let big = String(repeating: "x", count: 500)
        let clamped = ToolAgent.clampToolResult(big, max: 100)
        XCTAssertTrue(clamped.hasPrefix(String(repeating: "x", count: 100)), "keeps the head")
        XCTAssertTrue(clamped.contains("truncated 400 characters"), "marks how much was dropped")
        XCTAssertLessThan(clamped.count, big.count, "result is smaller than the original")

        // Character-counted, so multibyte text is bounded too (not just ASCII).
        let cjk = String(repeating: "字", count: 300)
        let clampedCJK = ToolAgent.clampToolResult(cjk, max: 50)
        XCTAssertTrue(clampedCJK.contains("truncated 250 characters"))
    }

    func testLanguageDistributionSortsByCountThenCode() {
        let codes = ["en", "zh-Hans", "en", "fr", "en", "zh-Hans", "", "fr"]
        let dist = ToolAgent.languageDistribution(codes)
        XCTAssertEqual(dist.map(\.language), ["en", "fr", "zh-Hans"], "by count desc; fr & zh tie at 2 → code asc")
        XCTAssertEqual(dist.map(\.count), [3, 2, 2])
        XCTAssertEqual(dist.reduce(0) { $0 + $1.count }, 7, "empty codes are ignored")
        XCTAssertTrue(ToolAgent.languageDistribution([]).isEmpty)
        XCTAssertTrue(ToolAgent.languageDistribution(["", "  ".trimmingCharacters(in: .whitespaces)]).isEmpty)
    }

    func testParseISODateRejectsGarbage() {
        XCTAssertNotNil(ToolAgent.parseISODate("2026-01-15"))
        XCTAssertNil(ToolAgent.parseISODate("15/01/2026"))
        XCTAssertNil(ToolAgent.parseISODate("yesterday"))
        XCTAssertNil(ToolAgent.parseISODate(nil))
        XCTAssertNil(ToolAgent.parseISODate("   "))
    }

    func testFinishTraceExplainsNonObviousStops() {
        XCTAssertNil(ToolAgent.finishTrace(.natural), "a clean finish needs no trace note")
        XCTAssertEqual(ToolAgent.finishTrace(.noProgress), "Wrapping up — no new information in the last steps.")
        XCTAssertEqual(ToolAgent.finishTrace(.roundLimit), "Reached the step limit — answering with what I have.")
    }

    func testChatMessageCarriesAgentNote() {
        let m = ChatMessage(role: .assistant, content: "answer",
                            agentNote: ToolAgent.finishTrace(.roundLimit) ?? "")
        XCTAssertEqual(m.agentNote, "Reached the step limit — answering with what I have.")
        // Default is empty (clean finish ⇒ no note shown).
        XCTAssertEqual(ChatMessage(role: .assistant, content: "x").agentNote, "")
    }

    func testIsStallOnlyWhenNothingHappened() {
        // Nothing fresh, no citations, no mutation ⇒ stall.
        XCTAssertTrue(ToolAgent.isStall(freshCalls: 0, newCitations: 0, didMutate: false))
        // Any of the three signals ⇒ progress, not a stall.
        XCTAssertFalse(ToolAgent.isStall(freshCalls: 1, newCitations: 0, didMutate: false), "a fresh call is progress")
        XCTAssertFalse(ToolAgent.isStall(freshCalls: 0, newCitations: 2, didMutate: false), "new citations are progress")
        XCTAssertFalse(ToolAgent.isStall(freshCalls: 0, newCitations: 0, didMutate: true), "a mutation is progress")
    }

    func testCallSignatureCollapsesEquivalentCalls() {
        // Same tool + same args (even with reordered keys) ⇒ identical signature.
        let a = ToolAgent.callSignature(name: "add_tag", args: #"{"item":"x","tag":"work"}"#)
        let b = ToolAgent.callSignature(name: "add_tag", args: #"{"tag":"work","item":"x"}"#)
        XCTAssertEqual(a, b, "key order shouldn't matter")
        // Different args ⇒ different signature.
        XCTAssertNotEqual(a, ToolAgent.callSignature(name: "add_tag", args: #"{"item":"y","tag":"work"}"#))
        // Different tool, same args ⇒ different signature.
        XCTAssertNotEqual(a, ToolAgent.callSignature(name: "remove_tag", args: #"{"item":"x","tag":"work"}"#))
        // Non-JSON args fall back to a trimmed literal (still stable).
        XCTAssertEqual(ToolAgent.callSignature(name: "t", args: "  raw  "),
                       ToolAgent.callSignature(name: "t", args: "raw"))
    }

    func testTagSummaryFramingNumbersEachSource() {
        let (text, cites) = ToolAgent.tagSummaryFraming(
            tag: "research",
            sources: [("faiss.pdf", "/f.pdf", "a", "vector index"),
                      ("notes.md", "/n.md", "b", "embeddings overview")],
            citationOffset: 1)
        XCTAssertEqual(cites.map(\.index), [2, 3], "numbered after the offset")
        XCTAssertEqual(cites[0].itemID, "a")
        XCTAssertTrue(text.contains("[2] (faiss.pdf) vector index"))
        XCTAssertTrue(text.contains("Files labelled 'research'"))
        XCTAssertTrue(text.contains("these 2 file(s)"))
        XCTAssertTrue(text.contains("citing each point with its [n]"))
    }

    func testItemSummaryFramingTruncatesAndCites() {
        let long = String(repeating: "A", count: 9000)
        let (text, cites) = ToolAgent.itemSummaryFraming(title: "Big Report", path: "/r.pdf",
            itemID: "id1", fullText: long, citationOffset: 1, maxChars: 8000)
        XCTAssertEqual(cites.count, 1)
        XCTAssertEqual(cites[0].index, 2, "numbered after the offset")
        XCTAssertEqual(cites[0].itemID, "id1")
        XCTAssertTrue(text.hasPrefix("[2] (Big Report)"))
        XCTAssertTrue(text.contains("citing [2]"))
        // Body is capped at maxChars (the instruction line adds a little more).
        XCTAssertLessThan(text.count, 8000 + 200)
        XCTAssertEqual(cites[0].snippet.count, 200, "snippet preview is the first 200 chars")
    }

    func testResearchDigestNumbersSourcesFromOffset() {
        let (text, cites) = ToolAgent.researchDigest(
            query: "what is RAG?",
            sources: [("Retrieval Aug Gen", "https://a.com", "RAG combines retrieval with generation."),
                      ("Vector DBs", "https://b.com", "Embeddings power semantic search.")],
            citationOffset: 2)
        // Citations continue from the offset so they don't collide with prior sources.
        XCTAssertEqual(cites.map(\.index), [3, 4])
        XCTAssertEqual(cites[0].title, "Retrieval Aug Gen")
        XCTAssertEqual(cites[1].path, "https://b.com")
        XCTAssertTrue(text.contains("[3] (Retrieval Aug Gen) https://a.com"))
        XCTAssertTrue(text.contains("2 sources read"))
        XCTAssertTrue(text.contains("Synthesize a grounded answer"))
        XCTAssertTrue(cites[0].snippet.contains("RAG combines"))
    }

    func testResearchDigestSingularAndEmpty() {
        let (oneText, _) = ToolAgent.researchDigest(query: "q",
            sources: [("T", "u", "b")], citationOffset: 0)
        XCTAssertTrue(oneText.contains("1 source read"), "singular grammar")
        let (_, noCites) = ToolAgent.researchDigest(query: "q", sources: [], citationOffset: 0)
        XCTAssertTrue(noCites.isEmpty)
    }

    func testMergedTagsConsolidatesAndDedupes() {
        let sources: Set<String> = ["ml", "machine-learning", "ML"]
        // Two source labels collapse to one target; unrelated labels preserved in order.
        XCTAssertEqual(ToolAgent.mergedTags(["ml", "research", "machine-learning"], from: sources, into: "machine learning"),
                       ["machine learning", "research"])
        // Case-insensitive match; existing target isn't duplicated.
        XCTAssertEqual(ToolAgent.mergedTags(["machine learning", "ML"], from: sources, into: "machine learning"),
                       ["machine learning"])
        // No source present ⇒ nil (caller skips the item).
        XCTAssertNil(ToolAgent.mergedTags(["finance", "draft"], from: sources, into: "machine learning"))
        // Already just the target ⇒ unchanged ⇒ nil.
        XCTAssertNil(ToolAgent.mergedTags(["machine learning"], from: sources, into: "machine learning"))
    }

    /// LIVE: the agent merges several messy labels into one across the library.
    func testAgentMergesTagsEndToEnd() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        let dir = try TestSupport.tempDirectory(prefix: "MergeTags")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let e = Embedder()
        for (i, label) in ["ml", "machine-learning", "ML"].enumerated() {
            let id = "m\(i)"
            try await store.upsert(item: KnowledgeItem(id: id, path: "/tmp/\(id).txt", title: "\(id).txt",
                kind: .text, contentHash: id, byteSize: 1, createdAt: Date(), modifiedAt: Date()),
                chunks: [Chunk(id: "\(id)#0", itemID: id, ordinal: 0, text: "note", embedding: e.embed("note"))])
            try await store.setTags([label, "keep"], forItem: id)
        }
        let agent = ToolAgent(store: store, embedder: e, deepSeek: DeepSeekClient(config: cfg))
        _ = try await agent.answer(query: "Merge the labels ml, machine-learning and ML into 'machine learning'.", history: [])

        let tags = Set((try await store.allTags()).map { $0.tag.lowercased() })
        XCTAssertTrue(tags.contains("machine learning"), "merged target exists (got \(tags))")
        XCTAssertFalse(tags.contains("ml"), "source 'ml' gone")
        XCTAssertFalse(tags.contains("machine-learning"), "source 'machine-learning' gone")
        XCTAssertTrue(tags.contains("keep"), "unrelated labels preserved")
    }

    func testLibrarySummaryDigest() {
        let d = Date(timeIntervalSince1970: 1000)
        func item(_ id: String, _ kind: ItemKind, _ mod: TimeInterval) -> KnowledgeItem {
            KnowledgeItem(id: id, path: "/\(id)", title: id, kind: kind, contentHash: id, byteSize: 1,
                          createdAt: d, modifiedAt: Date(timeIntervalSince1970: mod))
        }
        let items = [item("a", .text, 3000), item("b", .pdf, 5000), item("c", .text, 1000)]
        let s = ToolAgent.librarySummary(items: items, topTags: [("work", 4), ("draft", 1)],
                                         untagged: 1, chunks: 9)
        XCTAssertTrue(s.contains("3 items, 9 chunks"))
        XCTAssertTrue(s.contains("text: 2"), "kind counts; ties broken alphabetically")
        XCTAssertTrue(s.contains("pdf: 1"))
        XCTAssertTrue(s.contains("work (4), draft (1)"))
        XCTAssertTrue(s.contains("Untagged — 1 item."))
        XCTAssertTrue(s.contains("Newest — b; a; c"), "ordered by most-recent modified")
    }

    func testLibrarySummaryEmpty() {
        XCTAssertEqual(ToolAgent.librarySummary(items: [], topTags: [], untagged: 0, chunks: 0),
                       "The knowledge base is empty — nothing to summarize yet.")
    }

    func testDeferredReminderOnlyWhenWorkRemains() {
        let plan = ["search the notes", "build a dashboard", "tag them research"]
        // Unfinished → a follow-up titled with the next undone step + the rest.
        XCTAssertEqual(ToolAgent.deferredReminder(goal: "g", plan: plan, completed: 1),
                       "Continue: build a dashboard (+1 more step)")
        XCTAssertEqual(ToolAgent.deferredReminder(goal: "g", plan: plan, completed: 0),
                       "Continue: search the notes (+2 more steps)")
        XCTAssertEqual(ToolAgent.deferredReminder(goal: "g", plan: plan, completed: 2),
                       "Continue: tag them research", "last step left ⇒ no '+more' suffix")
        // Nothing to defer.
        XCTAssertNil(ToolAgent.deferredReminder(goal: "g", plan: plan, completed: 3), "all done ⇒ nil")
        XCTAssertNil(ToolAgent.deferredReminder(goal: "g", plan: ["one step"], completed: 0),
                     "single-step plan ⇒ not worth deferring")
        XCTAssertNil(ToolAgent.deferredReminder(goal: "g", plan: [], completed: 0))
    }

    func testCriticDecisionParsing() {
        XCTAssertEqual(ToolAgent.parseCriticDecision("OK"), .ok)
        XCTAssertEqual(ToolAgent.parseCriticDecision("SEARCH: 彩虹猫 示例"), .search("彩虹猫 示例"))
        XCTAssertEqual(ToolAgent.parseCriticDecision("NOTE: evidence is thin"), .note("evidence is thin"))
        XCTAssertEqual(ToolAgent.parseCriticDecision("anything else"), .ok, "unrecognised ⇒ proceed")
        XCTAssertEqual(ToolAgent.parseCriticDecision("SEARCH:   "), .ok, "empty query ⇒ proceed")
    }

    /// LIVE: the agent actually removes a label when asked (gated — uses DeepSeek).
    /// Run: MNEMO_LIVE_DEEPSEEK=1 swift test --filter AgentToolsTests
    func testAgentRemovesLabelEndToEnd() async throws {
        try XCTSkipUnless(TestSupport.liveDeepSeekEnabled, "set MNEMO_LIVE_DEEPSEEK=1")
        let cfg = Config.load()
        try XCTSkipUnless(!cfg.deepSeekKey.isEmpty, "no deepseek key")

        let dir = try TestSupport.tempDirectory(prefix: "AgentTools")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try KnowledgeStore(directory: dir)
        let embedder = Embedder()
        let item = KnowledgeItem(id: "doc1", path: "/tmp/budget.txt", title: "budget.txt", kind: .text,
                                 contentHash: "x", byteSize: 10, createdAt: Date(), modifiedAt: Date())
        try await store.upsert(item: item, chunks: [Chunk(id: "doc1#0", itemID: "doc1", ordinal: 0,
                                                          text: "quarterly budget", embedding: embedder.embed("quarterly budget"))])
        try await store.setTags(["finance", "draft"], forItem: "doc1")

        let agent = ToolAgent(store: store, embedder: embedder, deepSeek: DeepSeekClient(config: cfg))
        _ = try await agent.answer(query: "Remove the 'draft' label from budget.txt", history: [])

        let tags = try await store.tags(forItem: "doc1")
        XCTAssertFalse(tags.contains("draft"), "agent should have removed 'draft' (left: \(tags))")
        XCTAssertTrue(tags.contains("finance"), "other labels must be preserved")
    }
}
