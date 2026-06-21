import SwiftUI

/// Brain & model status, plus where data lives.
struct SettingsView: View {
    let services: Services
    @State private var itemCount = 0
    @State private var chunkCount = 0
    @State private var topK = 8
    @State private var temperature = 0.3
    @State private var multimodal = true
    @State private var visionEngine: VisionEngine = .gemma
    /// Ordered ingest-engine preference (primary first) with auto-fallback.
    @State private var engineOrder: [VisionEngine] = [.gemma]
    @State private var queryRewrite = false
    @State private var agentic = true
    @State private var agenticCritic = true
    @State private var buildEngine: BuildEngine = .deepseek
    @State private var contextBudget = 96_000
    @State private var autoTag = true
    @State private var keywordWeight = 0.3
    @State private var model = "deepseek-chat"
    @State private var deepSeekKeyInput = ""
    @State private var deepSeekKeyMessage = ""
    @State private var serpApiKeyInput = ""
    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var checkingOllama = false
    @State private var confirmingClear = false
    @State private var reindexing = false
    @State private var watchedRoots: [URL] = []
    @State private var pinnedFacts: [PinnedFact] = []
    @State private var newFact = ""

    /// Identifiable wrapper so pinned facts can drive a ForEach.
    private struct PinnedFact: Identifiable { let id: String; let fact: String }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: DS.Space.x6) {
            SectionHeader("Settings", subtitle: "Brains, models, and storage")

            GlassPanel {
                VStack(alignment: .leading, spacing: DS.Space.x4) {
                    Text("Agent brain").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    StatusDot(ok: services.isDeepSeekConfigured,
                              label: services.isDeepSeekConfigured
                                  ? "DeepSeek connected · \(services.deepSeekKeySource)"
                                  : "DeepSeek key missing")
                    VStack(alignment: .leading, spacing: DS.Space.x2) {
                        Text("DeepSeek API key").font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.textTertiary)
                        HStack(spacing: DS.Space.x3) {
                            SecureField("sk-…", text: $deepSeekKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 440)
                                .onSubmit(saveDeepSeekKey)
                                .accessibilityIdentifier("settings.deepSeekKey")
                            DSButton("Save key", icon: "key", kind: .secondary, action: saveDeepSeekKey)
                            DSButton("Clear", icon: "xmark.circle", kind: .ghost, action: clearDeepSeekKey)
                        }
                        Text(deepSeekKeyMessage.isEmpty
                             ? "Stored in macOS Keychain. Environment variables still override for dev/test."
                             : deepSeekKeyMessage)
                            .font(DS.Typo.caption)
                            .foregroundStyle(deepSeekKeyMessage.hasPrefix("Could not") ? DS.ColorToken.danger : DS.ColorToken.textTertiary)

                        Text("SerpAPI key (web search)").font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.textTertiary).padding(.top, DS.Space.x2)
                        HStack(spacing: DS.Space.x3) {
                            SecureField("optional — leave blank for keyless search", text: $serpApiKeyInput)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 440)
                                .onSubmit { services.settings.serpApiKey = serpApiKeyInput }
                                .accessibilityIdentifier("settings.serpApiKey")
                            DSButton("Save", icon: "key", kind: .secondary) {
                                services.settings.serpApiKey = serpApiKeyInput
                            }
                        }
                        Text("Web search works without a key (DuckDuckGo). Add a SerpAPI key for richer Google results.")
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    }
                    Picker("Model", selection: $model) {
                        Text("deepseek-chat (fast)").tag("deepseek-chat")
                        Text("deepseek-reasoner (deep)").tag("deepseek-reasoner")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model) { _, v in services.settings.model = v }
                    Divider().overlay(DS.ColorToken.borderSubtle)
                    Text("Multimodal").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    HStack(spacing: DS.Space.x3) {
                        StatusDot(ok: ollamaStatus.isReady,
                                  label: ollamaStatus.label(model: services.config.ollamaVisionModel))
                        Spacer()
                        DSButton(checkingOllama ? "Checking…" : "Check again",
                                 icon: "arrow.clockwise", kind: .ghost) {
                            Task { await refreshOllamaStatus() }
                        }
                        .disabled(checkingOllama)
                    }
                    Text(ollamaStatus.detail(model: services.config.ollamaVisionModel,
                                             baseURL: services.config.ollamaBaseURL))
                        .font(DS.Typo.caption)
                        .foregroundStyle(ollamaStatus.isReady ? DS.ColorToken.textTertiary : DS.ColorToken.danger)
                    if !ollamaStatus.isReady {
                        ollamaSetupCallout
                    }
                    Divider().overlay(DS.ColorToken.borderSubtle)
                    Text("Embeddings").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    StatusDot(ok: services.embedder.isAvailable,
                              label: "Apple NLEmbedding · \(services.embedder.dimension)-dim (on-device)")
                    Divider().overlay(DS.ColorToken.borderSubtle)
                    Text("Live watching").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    StatusDot(ok: services.isWatching,
                              label: services.isWatching
                                  ? "Watching \(services.watchedCount) folder\(services.watchedCount == 1 ? "" : "s") (FSEvents)"
                                  : "Not watching — ingest a folder to begin")
                    if !watchedRoots.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.x1) {
                            ForEach(watchedRoots, id: \.self) { root in
                                HStack(spacing: DS.Space.x2) {
                                    Image(systemName: "folder").font(.system(size: 11))
                                        .foregroundStyle(DS.ColorToken.textTertiary)
                                    Text(root.path).font(DS.Typo.caption)
                                        .foregroundStyle(DS.ColorToken.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Button { removeRoot(root) } label: {
                                        Image(systemName: "xmark.circle").font(.system(size: 12))
                                            .foregroundStyle(DS.ColorToken.textTertiary)
                                    }.buttonStyle(.plain).help("Stop watching & remove its items")
                                }
                            }
                        }
                        .padding(.top, DS.Space.x1)
                    }
                }
                .padding(DS.Space.x6)
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: DS.Space.x4) {
                    HStack {
                        Text("Retrieval & generation").font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.textTertiary)
                        Spacer()
                        Text("applies to your next message").font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.textTertiary)
                    }
                    Stepper(value: $topK, in: 1...20) {
                        Text("Sources retrieved (top-k): \(topK)").font(DS.Typo.body)
                            .foregroundStyle(DS.ColorToken.textSecondary)
                    }.onChange(of: topK) { _, v in services.settings.topK = v }

                    VStack(alignment: .leading, spacing: DS.Space.x1) {
                        Text("Answer temperature: \(String(format: "%.2f", temperature))")
                            .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textSecondary)
                        Slider(value: $temperature, in: 0...1)
                            .onChange(of: temperature) { _, v in services.settings.temperature = v }
                    }
                    VStack(alignment: .leading, spacing: DS.Space.x1) {
                        Text("Keyword vs. semantic: \(String(format: "%.2f", keywordWeight))")
                            .font(DS.Typo.body).foregroundStyle(DS.ColorToken.textSecondary)
                        Slider(value: $keywordWeight, in: 0...1)
                            .onChange(of: keywordWeight) { _, v in services.settings.keywordWeight = v }
                        Text("Higher = exact terms (names, codes) matter more in search.")
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    }
                    Toggle(isOn: $multimodal) {
                        Text("Understand images, PDFs & documents (vision engine)").font(DS.Typo.body)
                            .foregroundStyle(DS.ColorToken.textSecondary)
                    }.onChange(of: multimodal) { _, v in services.settings.multimodal = v }
                        .accessibilityIdentifier("settings.multimodal")
                    if multimodal {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ingest engines — tried top to bottom")
                                .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textSecondary)
                            Text("Pick which engines to use and the order. The first handles each file; if it fails or times out, the next enabled one takes over automatically.")
                                .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            // Active engines — enabled, in priority order (reorderable, removable).
                            ForEach(Array(engineOrder.enumerated()), id: \.element) { idx, eng in
                                engineRow(eng, index: idx)
                            }
                            // Available engines — not currently used; tap to enable.
                            let available = VisionEngine.allCases.filter { !engineOrder.contains($0) }
                            if !available.isEmpty {
                                Text("Available")
                                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                                    .padding(.top, DS.Space.x1)
                                ForEach(available) { eng in availableRow(eng) }
                            }
                        }
                        .padding(.leading, DS.Space.x4)
                        .accessibilityIdentifier("settings.visionEngineOrder")
                    }
                    Toggle(isOn: $autoTag) {
                        Text("Auto-tag new items from their folder").font(DS.Typo.body)
                            .foregroundStyle(DS.ColorToken.textSecondary)
                    }.onChange(of: autoTag) { _, v in services.settings.autoTag = v }
                        .accessibilityIdentifier("settings.autoTag")
                    Toggle(isOn: $queryRewrite) {
                        Text("Rewrite queries before search (better recall)").font(DS.Typo.body)
                            .foregroundStyle(DS.ColorToken.textSecondary)
                    }.onChange(of: queryRewrite) { _, v in services.settings.queryRewrite = v }
                        .accessibilityIdentifier("settings.queryRewrite")
                    Toggle(isOn: $agentic) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agentic mode (multi-hop tool search)").font(DS.Typo.body)
                                .foregroundStyle(DS.ColorToken.textSecondary)
                            Text("DeepSeek searches your files itself, multiple times if needed.")
                                .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                        }
                    }.onChange(of: agentic) { _, v in services.settings.agentic = v }
                        .accessibilityIdentifier("settings.agentic")
                    if agentic {
                        Toggle(isOn: $agenticCritic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Critic pass (verify before answering)").font(DS.Typo.body)
                                    .foregroundStyle(DS.ColorToken.textSecondary)
                                Text("A reviewer checks the evidence first — can run one more search or make the answer hedge.")
                                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            }
                        }.onChange(of: agenticCritic) { _, v in services.settings.agenticCritic = v }
                            .accessibilityIdentifier("settings.agenticCritic")
                            .padding(.leading, DS.Space.x4)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Build agent (create_artifact)", selection: $buildEngine) {
                            ForEach(BuildEngine.allCases) { Text($0.label).tag($0) }
                        }
                        .onChange(of: buildEngine) { _, v in services.settings.buildEngine = v }
                        .accessibilityIdentifier("settings.buildEngine")
                        Text(buildEngine.detail)
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Conversation memory", selection: $contextBudget) {
                            Text("Focused · 32K").tag(32_000)
                            Text("Balanced · 64K").tag(64_000)
                            Text("Long · 96K").tag(96_000)
                            Text("Extended · 128K").tag(128_000)
                            Text("Huge · 256K").tag(256_000)
                            Text("Vast · 512K").tag(512_000)
                            Text("Maximum · 1M").tag(1_000_000)
                        }
                        .onChange(of: contextBudget) { _, v in services.settings.contextBudget = v }
                        .accessibilityIdentifier("settings.contextBudget")
                        Text("How much chat history the agent keeps before compacting the oldest turns. The models now support a 1M-token window — bigger keeps more verbatim.")
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    }
                }
                .tint(DS.ColorToken.iris)
                .padding(DS.Space.x6)
            }

            memoryPanel

            GlassPanel {
                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    Text("Knowledge base").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    HStack(spacing: DS.Space.x8) {
                        metric("\(itemCount)", "items")
                        metric("\(chunkCount)", "chunks")
                    }
                    Text(services.store.dbURL.path)
                        .font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Divider().overlay(DS.ColorToken.borderSubtle)
                    HStack(spacing: DS.Space.x3) {
                        DSButton(reindexing ? "Rebuilding…" : "Rebuild index",
                                 icon: "arrow.triangle.2.circlepath", kind: .secondary) { rebuild() }
                            .disabled(reindexing || itemCount == 0)
                        DSButton("Clear knowledge base…", icon: "trash", kind: .ghost) { confirmingClear = true }
                            .confirmationDialog("Remove all \(itemCount) ingested items and forget watched folders? Your chats are kept.",
                                                isPresented: $confirmingClear, titleVisibility: .visible) {
                                Button("Clear everything", role: .destructive) {
                                    services.clearKnowledge()
                                    itemCount = 0; chunkCount = 0
                                }
                                Button("Cancel", role: .cancel) {}
                            }
                    }
                }
                .padding(DS.Space.x6)
            }
        }
        .padding(DS.Space.x8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task {
            itemCount = (try? await services.store.itemCount()) ?? 0
            chunkCount = (try? await services.store.chunkCount()) ?? 0
            ollamaStatus = services.ollamaStatus
            await refreshOllamaStatus()
        }
        .onAppear {
            topK = services.settings.topK
            temperature = services.settings.temperature
            multimodal = services.settings.multimodal
            visionEngine = services.settings.visionEngine
            engineOrder = services.settings.visionEngineOrder   // the enabled subset, in order
            queryRewrite = services.settings.queryRewrite
            agentic = services.settings.agentic
            agenticCritic = services.settings.agenticCritic
            buildEngine = services.settings.buildEngine
            contextBudget = services.settings.contextBudget
            autoTag = services.settings.autoTag
            model = services.settings.model
            keywordWeight = services.settings.keywordWeight
            deepSeekKeyInput = services.settings.deepSeekKey
            serpApiKeyInput = services.settings.serpApiKey
            ollamaStatus = services.ollamaStatus
            watchedRoots = services.roots.roots
        }
    }

    /// CLI-availability warning text for an engine, or nil when it's usable.
    private func engineWarning(_ eng: VisionEngine) -> String? {
        if eng == .claudeCode, !ClaudeCodeClient.isAvailable { return "⚠︎ `claude` CLI not found — this engine will be skipped." }
        if eng == .codex, !CodexCliClient.isAvailable { return "⚠︎ `codex` CLI not found — this engine will be skipped." }
        return nil
    }

    /// One ACTIVE (enabled) engine row: rank badge, label, availability note, reorder
    /// controls, and a Disable button. Position = priority (top is tried first).
    @ViewBuilder private func engineRow(_ eng: VisionEngine, index: Int) -> some View {
        HStack(spacing: DS.Space.x3) {
            Text("\(index + 1)")
                .font(DS.Typo.caption.monospacedDigit())
                .foregroundStyle(index == 0 ? DS.ColorToken.iris : DS.ColorToken.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(eng.label).font(DS.Typo.body).foregroundStyle(DS.ColorToken.textSecondary)
                    if index == 0 {
                        Text("primary").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.iris)
                    }
                }
                if let warn = engineWarning(eng) {
                    Text(warn).font(DS.Typo.caption).foregroundStyle(DS.ColorToken.danger)
                } else {
                    Text(eng.detail).font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                }
            }
            Spacer()
            Button { moveEngine(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0)
                .accessibilityLabel("Move \(eng.label) up")
            Button { moveEngine(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == engineOrder.count - 1)
                .accessibilityLabel("Move \(eng.label) down")
            // Can't disable the last remaining engine (something must handle vision).
            Button { disableEngine(eng) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).disabled(engineOrder.count <= 1)
                .foregroundStyle(engineOrder.count <= 1 ? DS.ColorToken.textTertiary : DS.ColorToken.danger)
                .accessibilityLabel("Disable \(eng.label)")
        }
    }

    /// One AVAILABLE (disabled) engine row: label, availability note, and an Enable button
    /// that appends it to the active order (lowest priority).
    @ViewBuilder private func availableRow(_ eng: VisionEngine) -> some View {
        HStack(spacing: DS.Space.x3) {
            Spacer().frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(eng.label).font(DS.Typo.body).foregroundStyle(DS.ColorToken.textTertiary)
                if let warn = engineWarning(eng) {
                    Text(warn).font(DS.Typo.caption).foregroundStyle(DS.ColorToken.danger)
                }
            }
            Spacer()
            Button { enableEngine(eng) } label: {
                Label("Enable", systemImage: "plus.circle").font(DS.Typo.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Enable \(eng.label)")
        }
    }

    /// Move the engine at `index` by `delta` (−1 up, +1 down). Bounds-checked.
    private func moveEngine(_ index: Int, by delta: Int) {
        let dest = index + delta
        guard engineOrder.indices.contains(index), engineOrder.indices.contains(dest) else { return }
        engineOrder.swapAt(index, dest)
        persistEngineOrder()
    }

    /// Enable an engine (append at lowest priority).
    private func enableEngine(_ eng: VisionEngine) {
        guard !engineOrder.contains(eng) else { return }
        engineOrder.append(eng)
        persistEngineOrder()
    }

    /// Disable an engine, keeping at least one active.
    private func disableEngine(_ eng: VisionEngine) {
        guard engineOrder.count > 1 else { return }
        engineOrder.removeAll { $0 == eng }
        persistEngineOrder()
    }

    /// Persist the enabled-and-ordered engine list and keep the primary engine in sync.
    private func persistEngineOrder() {
        services.settings.visionEngineOrder = engineOrder   // setter normalizes + syncs visionEngine
        visionEngine = engineOrder.first ?? .gemma
    }

    /// Long-term memory: the facts the agent always remembers across conversations.
    private var memoryPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: DS.Space.x3) {
                Text("Long-term memory").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                Text("Facts the agent always remembers — injected into every conversation, never compacted.")
                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                if pinnedFacts.isEmpty {
                    Text("Nothing pinned yet. Tell the agent to \u{201C}remember\u{201D} something, or add one below.")
                        .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(pinnedFacts) { f in
                            HStack(spacing: DS.Space.x3) {
                                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DS.ColorToken.iris)
                                Text(f.fact).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: DS.Space.x3)
                                Button { removeFact(f.id) } label: {
                                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(DS.ColorToken.textTertiary)
                                }.buttonStyle(.plain).help("Forget this fact")
                            }
                            .padding(.vertical, DS.Space.x2)
                            if f.id != pinnedFacts.last?.id { Rectangle().fill(DS.ColorToken.borderSubtle).frame(height: 1) }
                        }
                    }
                }
                HStack(spacing: DS.Space.x2) {
                    Image(systemName: "plus.circle").foregroundStyle(DS.ColorToken.iris)
                    TextField("Add a fact to remember…", text: $newFact)
                        .textFieldStyle(.plain).font(DS.Typo.body).onSubmit { addFact() }
                    if !newFact.trimmingCharacters(in: .whitespaces).isEmpty {
                        DSButton("Pin", icon: "pin", kind: .primary) { addFact() }
                    }
                }
                .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
                .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.ColorToken.borderSubtle, lineWidth: 1))
            }
            .padding(DS.Space.x6)
        }
        .task { await loadFacts() }
    }

    private func loadFacts() async {
        let facts = (try? await services.store.allPinnedFacts()) ?? []
        pinnedFacts = facts.map { PinnedFact(id: $0.id, fact: $0.fact) }
    }
    private func addFact() {
        let f = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return }
        newFact = ""
        Task { try? await services.store.addPinnedFact(f); await loadFacts() }
    }
    private func removeFact(_ id: String) {
        Task { try? await services.store.removePinnedFact(id: id); await loadFacts() }
    }

    private var ollamaSetupCallout: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text("Required local model setup").font(DS.Typo.caption)
                .foregroundStyle(DS.ColorToken.textTertiary)
            Text("ollama pull \(services.config.ollamaVisionModel)\nollama serve")
                .font(DS.Typo.mono)
                .foregroundStyle(DS.ColorToken.textPrimary)
                .textSelection(.enabled)
                .padding(DS.Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.ColorToken.canvasRaised,
                            in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.ColorToken.borderSubtle, lineWidth: 1))
        }
    }

    private func refreshOllamaStatus() async {
        checkingOllama = true
        ollamaStatus = await services.refreshOllamaStatus()
        checkingOllama = false
    }

    private func saveDeepSeekKey() {
        let trimmed = deepSeekKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if services.settings.setDeepSeekKey(trimmed) {
            deepSeekKeyInput = services.settings.deepSeekKey
            deepSeekKeyMessage = trimmed.isEmpty
                ? "DeepSeek key cleared. Add one before asking live questions."
                : "Saved to macOS Keychain. The next message uses this key."
        } else {
            deepSeekKeyMessage = "Could not save to macOS Keychain."
        }
    }

    private func clearDeepSeekKey() {
        deepSeekKeyInput = ""
        saveDeepSeekKey()
    }

    private func removeRoot(_ url: URL) {
        services.removeRoot(url)
        watchedRoots = services.roots.roots
    }

    private func rebuild() {
        reindexing = true
        services.rebuildIndex()
        // Re-embedding runs detached; release the button shortly after kickoff.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            reindexing = false
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(DS.Typo.title1).foregroundStyle(DS.ColorToken.textPrimary)
            Text(label).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
        }
    }
}
