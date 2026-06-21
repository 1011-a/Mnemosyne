import Foundation
import Observation

/// Main-actor conversation state for the chat screen. Owns the message list,
/// the live streaming buffer, citation attachment, and thread persistence.
@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    /// Text of the in-flight assistant turn as tokens arrive.
    var streamingText: String = ""
    /// Live reasoner thinking trace for the in-flight turn.
    var streamingReasoning: String = ""
    var pendingCitations: [Citation] = []
    var isStreaming = false
    var errorText: String?

    // Threads
    var threads: [ChatThread] = []
    var threadQuery: String = ""
    private(set) var threadID: String
    private(set) var title: String = "New chat"
    private var threadCreatedAt = Date()
    private var threadPinned = false
    private var activeModel = ""

    /// Status line shown during agentic (tool-loop) turns, e.g. "Searching: …".
    var agentStatus: String = ""
    /// The agent's plan for a complex goal (empty for simple turns).
    var agentPlan: [String] = []
    /// How many leading plan steps the agent has completed this turn.
    var completedSteps: Int = 0
    /// Why the in-flight agentic turn ended (e.g. step-limit) — attached on commit.
    private var pendingFinishNote: String = ""
    /// A live, accumulating trace of the agent's tool activity this turn.
    var agentTrace: [String] = []

    /// Proactive, content-derived suggestions shown in the empty Ask hero.
    var suggestions: [Suggestion] = []

    /// The running compaction brief for this thread, if older turns were summarized
    /// (drives the subtle "memory compacted" indicator). nil ⇒ full history in play.
    var memorySummary: String?

    /// Facts pinned to long-term memory (lowercased) — to avoid re-suggesting a pin.
    var pinnedFacts: [String] = []

    /// Refresh the stored compaction summary + pinned facts for the current thread.
    func loadMemorySummary() async {
        memorySummary = (try? await store.loadThreadSummary(threadID: threadID))?.summary
        pinnedFacts = ((try? await store.allPinnedFacts()) ?? []).map { $0.fact.lowercased() }
    }

    /// Pin a fact to long-term memory (from the "Remember this?" chip).
    func pinFact(_ fact: String) async {
        try? await store.addPinnedFact(fact)
        pinnedFacts = ((try? await store.allPinnedFacts()) ?? []).map { $0.fact.lowercased() }
    }

    /// Forget this thread's compaction summary — the next turn recompacts from scratch.
    func forgetMemory() async {
        try? await store.deleteThreadSummary(threadID: threadID)
        memorySummary = nil
    }

    /// Rough context usage for the current thread: (estimated tokens, budget).
    var contextEstimate: (used: Int, budget: Int) {
        (ContextManager.totalTokens(messages), settings.contextBudget)
    }

    /// Refresh autonomous suggestions from the current knowledge base.
    func loadSuggestions() async {
        suggestions = await SuggestionEngine.suggestions(from: store)
    }

    private let makeRAG: @MainActor () -> RAGAgent
    private let makeTool: @MainActor () -> ToolAgent
    private let store: KnowledgeStore
    private let settings: SettingsStore
    private var task: Task<Void, Never>?

    init(makeRAG: @escaping @MainActor () -> RAGAgent,
         makeTool: @escaping @MainActor () -> ToolAgent,
         store: KnowledgeStore, settings: SettingsStore) {
        self.makeRAG = makeRAG
        self.makeTool = makeTool
        self.store = store
        self.settings = settings
        self.threadID = UUID().uuidString
        loadThreads()
    }

    // MARK: Threads

    func loadThreads() {
        let q = threadQuery
        Task {
            threads = q.isEmpty
                ? (try? await store.allThreads()) ?? []
                : (try? await store.searchThreads(query: q)) ?? []
        }
    }

    /// Re-run thread loading against the current `threadQuery`.
    func searchThreads() { loadThreads() }

    /// On launch, resume the most recent conversation if the view is empty.
    func resumeMostRecent() {
        guard messages.isEmpty else { return }
        Task {
            let all = (try? await store.allThreads()) ?? []
            if let first = all.first { open(first) }
        }
    }

    /// A deterministic, network-free conversation for UI tests (`--uitest`).
    /// The answer carries a unique marker so an XCUITest can assert Copy works.
    func loadUITestFixture() {
        title = "UI Test"
        messages = [
            ChatMessage(role: .user, content: "What is in my knowledge base?"),
            ChatMessage(role: .assistant,
                        content: "Your knowledge base holds 88 items across images, PDFs and notes. MARKER_COPY_OK.",
                        citations: [Citation(index: 1, title: "notes.md", path: "/tmp/notes.md",
                                             snippet: "", itemID: "u1")],
                        model: "deepseek-chat")
        ]
    }

    func newThread() {
        task?.cancel()
        messages = []; streamingText = ""; pendingCitations = []
        isStreaming = false; errorText = nil
        threadID = UUID().uuidString
        title = "New chat"
        threadCreatedAt = Date()
        threadPinned = false
        memorySummary = nil
    }

    func open(_ thread: ChatThread) {
        guard thread.id != threadID else { return }
        task?.cancel(); isStreaming = false; streamingText = ""
        threadID = thread.id; title = thread.title
        threadCreatedAt = thread.createdAt; threadPinned = thread.pinned
        memorySummary = nil
        Task {
            messages = (try? await store.loadMessages(threadID: thread.id)) ?? []
            await loadMemorySummary()
        }
    }

    func deleteThread(_ thread: ChatThread) {
        Task {
            try? await store.deleteThread(id: thread.id)
            if thread.id == threadID { newThread() }
            loadThreads()
        }
    }

    func rename(_ thread: ChatThread, to newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if thread.id == threadID { title = t }
        Task {
            try? await store.updateThreadTitle(id: thread.id, title: t)
            loadThreads()
        }
    }

    func togglePin(_ thread: ChatThread) {
        let newValue = !thread.pinned
        if thread.id == threadID { threadPinned = newValue }
        Task {
            try? await store.setThreadPinned(id: thread.id, pinned: newValue)
            loadThreads()
        }
    }

    // MARK: Send

    func send(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isStreaming else { return }
        let history = messages
        let isFirstTurn = messages.isEmpty
        activeModel = settings.model   // stamp this turn's answer with the chosen model
        messages.append(ChatMessage(role: .user, content: query))
        errorText = nil
        isStreaming = true
        streamingText = ""
        streamingReasoning = ""
        agentStatus = ""
        pendingCitations = []

        if settings.agentic {
            sendAgentic(query: query, history: history, firstTurn: isFirstTurn, agent: makeTool())
        } else {
            sendStreaming(query: query, history: history, firstTurn: isFirstTurn, agent: makeRAG())
        }
    }

    /// One-shot RAG with token streaming.
    private func sendStreaming(query: String, history: [ChatMessage], firstTurn: Bool, agent: RAGAgent) {
        task = Task {
            do {
                let prepared = try await agent.prepare(query: query, history: history)
                await MainActor.run { self.pendingCitations = prepared.citations }
                for try await delta in agent.stream(prepared.messages) {
                    if Task.isCancelled { break }
                    await MainActor.run { self.apply(delta) }
                }
                await MainActor.run { self.commit(prepared.citations, firstTurn: firstTurn, query: query) }
            } catch {
                await MainActor.run { self.failTurn(error) }
            }
        }
    }

    /// Multi-hop agentic tool loop: shows search status, then streams the answer.
    private func sendAgentic(query: String, history: [ChatMessage], firstTurn: Bool, agent: ToolAgent) {
        agentPlan = []; agentTrace = []; completedSteps = 0; pendingFinishNote = ""
        task = Task {
            var cites: [Citation] = []
            let tid = threadID
            let stream = agent.answerStream(
                query: query, history: history, threadID: tid,
                onStatus: { status in Task { @MainActor in
                    self.agentStatus = status
                    let s = status.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty, s != "Planning…", self.agentTrace.last != s {
                        self.agentTrace.append(s)
                        if self.agentTrace.count > 20 { self.agentTrace.removeFirst() }
                    }
                } },
                onCitations: { c in Task { @MainActor in self.pendingCitations = c } },
                onPlan: { plan in Task { @MainActor in self.agentPlan = plan } },
                onPlanStep: { n in Task { @MainActor in self.completedSteps = n } },
                onFinishNote: { note in Task { @MainActor in self.pendingFinishNote = note ?? "" } })
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    await MainActor.run { self.agentStatus = ""; self.apply(delta) }
                }
                cites = await MainActor.run { self.pendingCitations }
                await MainActor.run { self.commit(cites, firstTurn: firstTurn, query: query) }
            } catch {
                await MainActor.run { self.failTurn(error) }
            }
        }
    }

    /// Route a streamed delta into the reasoning trace or the answer buffer.
    private func apply(_ delta: StreamDelta) {
        switch delta {
        case .reasoning(let r): streamingReasoning += r
        case .answer(let a):    streamingText += a
        }
    }

    func cancel() {
        task?.cancel()
        if isStreaming { commit(pendingCitations, firstTurn: false, query: "") }
    }

    /// Render the conversation as shareable Markdown, citations included.
    func exportMarkdown() -> String {
        var md = "# \(title)\n\n"
        for m in messages {
            switch m.role {
            case .user:      md += "### You\n\n\(m.content)\n\n"
            case .assistant: md += "### Mnemosyne\n\n\(m.content)\n\n"
            default:         continue
            }
            if !m.reasoning.isEmpty {
                md += "<details>\n<summary>Reasoning</summary>\n\n\(m.reasoning)\n\n</details>\n\n"
            }
            if !m.citations.isEmpty {
                md += "**Sources**\n\n"
                for c in m.citations {
                    var line = "- [\(c.index)] \(c.title)"
                    if !c.snippetPreview.isEmpty { line += " — \(c.snippetPreview)" }
                    line += " `\(c.path)`"
                    md += line + "\n"
                }
                md += "\n"
            }
        }
        return md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Drop the last assistant turn and re-ask the preceding user question.
    func regenerateLast() {
        guard !isStreaming else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        guard let lastUser = messages.last(where: { $0.role == .user })?.content else { return }
        if messages.last?.role == .user { messages.removeLast() }
        send(lastUser)
    }

    private func commit(_ citations: [Citation], firstTurn: Bool, query: String) {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let used = RAGAgent.referencedIndices(in: text)
            let kept = used.isEmpty ? citations : citations.filter { used.contains($0.index) }
            messages.append(ChatMessage(role: .assistant, content: text, citations: kept,
                                        model: activeModel,
                                        reasoning: streamingReasoning.trimmingCharacters(in: .whitespacesAndNewlines),
                                        agentNote: pendingFinishNote))
            // Track which sources the agent actually leaned on.
            let citedIDs = kept.map(\.itemID)
            Task { try? await store.recordCitations(itemIDs: citedIDs) }
        }
        streamingText = ""
        streamingReasoning = ""
        agentStatus = ""
        pendingCitations = []
        pendingFinishNote = ""
        isStreaming = false
        persist()
        if firstTurn, title == "New chat", !query.isEmpty { autoTitle(from: query) }
        // The turn may have compacted older history — refresh the memory indicator.
        Task { await loadMemorySummary() }
    }

    private func failTurn(_ error: Error) {
        errorText = error.localizedDescription
        messages.append(ChatMessage(role: .assistant,
            content: "⚠️ I couldn't complete that: \(error.localizedDescription)"))
        streamingText = ""
        streamingReasoning = ""
        isStreaming = false
        persist()
    }

    // MARK: Persistence

    private func persist() {
        guard !messages.isEmpty else { return }
        let snapshot = messages
        let tid = threadID
        let thread = ChatThread(id: tid, title: title, createdAt: threadCreatedAt,
                                updatedAt: Date(), pinned: threadPinned)
        Task {
            try? await store.upsertThread(thread)
            try? await store.saveMessages(snapshot, threadID: tid)
            loadThreads()
        }
    }

    private func autoTitle(from query: String) {
        let tid = threadID
        let rag = makeRAG()
        Task {
            guard let suggested = await rag.suggestTitle(from: query) else { return }
            guard tid == self.threadID else { return }   // user may have switched threads
            self.title = suggested
            self.persist()
        }
    }
}
