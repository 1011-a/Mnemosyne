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
    @State private var queryRewrite = false
    @State private var agentic = true
    @State private var autoTag = true
    @State private var keywordWeight = 0.3
    @State private var model = "deepseek-chat"
    @State private var deepSeekKeyInput = ""
    @State private var deepSeekKeyMessage = ""
    @State private var ollamaStatus: OllamaStatus = .unknown
    @State private var checkingOllama = false
    @State private var confirmingClear = false
    @State private var reindexing = false
    @State private var watchedRoots: [URL] = []

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
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("Vision engine", selection: $visionEngine) {
                                ForEach(VisionEngine.allCases) { eng in
                                    Text(eng.label).tag(eng)
                                }
                            }
                            .onChange(of: visionEngine) { _, v in services.settings.visionEngine = v }
                            .accessibilityIdentifier("settings.visionEngine")
                            Text(visionEngine.detail)
                                .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            if visionEngine == .claudeCode, !ClaudeCodeClient.isAvailable {
                                Text("⚠︎ `claude` CLI not found on this Mac — install Claude Code or it falls back to nothing for images.")
                                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.danger)
                            }
                            if visionEngine == .codex, !CodexCliClient.isAvailable {
                                Text("⚠︎ `codex` CLI not found on this Mac — install Codex CLI or choose another vision engine.")
                                    .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.danger)
                            }
                        }
                        .padding(.leading, DS.Space.x4)
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
                }
                .tint(DS.ColorToken.iris)
                .padding(DS.Space.x6)
            }

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
            queryRewrite = services.settings.queryRewrite
            agentic = services.settings.agentic
            autoTag = services.settings.autoTag
            model = services.settings.model
            keywordWeight = services.settings.keywordWeight
            deepSeekKeyInput = services.settings.deepSeekKey
            ollamaStatus = services.ollamaStatus
            watchedRoots = services.roots.roots
        }
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
