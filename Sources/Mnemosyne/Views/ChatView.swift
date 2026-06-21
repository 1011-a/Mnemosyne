import SwiftUI

/// The conversational surface. Streams grounded answers and shows citations.
struct ChatView: View {
    @Bindable var vm: ChatViewModel
    var onIngest: () -> Void = {}
    @State private var draft = ""
    @State private var showMemory = false
    @State private var dismissedPins: Set<String> = []
    @State private var focusBump = 0

    /// A durable fact from the latest user turn worth offering to pin — unless it's
    /// already pinned or the user dismissed it.
    private var pinSuggestion: String? {
        guard let lastUser = vm.messages.last(where: { $0.role == .user })?.content,
              let fact = MemoryHints.durableFactCandidate(lastUser),
              !dismissedPins.contains(fact.lowercased()),
              !vm.pinnedFacts.contains(fact.lowercased()) else { return nil }
        return fact
    }

    /// One-tap confirmation for a previewed action — so the user needn't type "apply".
    private var approveBar: some View {
        HStack(spacing: DS.Space.x2) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(DS.ColorToken.iris)
            Text("Needs your OK to proceed").font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
            Spacer(minLength: DS.Space.x3)
            Button { vm.send(ConfirmationHints.approveMessage) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10))
                    Text("Approve").font(DS.Typo.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                .background(DS.ColorToken.iris, in: Capsule())
            }.buttonStyle(.plain)
            Button { vm.send(ConfirmationHints.skipMessage) } label: {
                Text("Skip").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                    .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                    .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.iris.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.iris.opacity(0.3)))
    }

    private func pinChip(_ fact: String) -> some View {
        HStack(spacing: DS.Space.x2) {
            Image(systemName: "pin").font(.system(size: 10)).foregroundStyle(DS.ColorToken.iris)
            Text("Remember this?").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textSecondary)
            Button("Pin to memory") {
                dismissedPins.insert(fact.lowercased())
                Task { await vm.pinFact(fact) }
            }
            .font(DS.Typo.caption).foregroundStyle(.white)
            .padding(.horizontal, DS.Space.x3).padding(.vertical, 2)
            .background(DS.ColorToken.iris, in: Capsule()).buttonStyle(.plain)
            Button { dismissedPins.insert(fact.lowercased()) } label: {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(DS.ColorToken.textTertiary)
            }.buttonStyle(.plain).help("Dismiss")
        }
        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
        .background(DS.ColorToken.iris.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(DS.ColorToken.iris.opacity(0.25), lineWidth: 1))
    }
    @State private var composerFocused = false
    @State private var motesEnergy: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Motes rest (0), half-gather when the prompt is focused (0.45), and fully
    /// gather when it has text (1) — eased so the field breathes into place.
    private func updateMotes() {
        let target: Double = !draft.isEmpty ? 1 : (composerFocused ? 0.45 : 0)
        if reduceMotion { motesEnergy = target }
        else { withAnimation(.easeOut(duration: 0.6)) { motesEnergy = target } }
    }

    // AI-first single column: lots of air, a centered reading width, the ask
    // field always present as the heart of the app. No panes.
    private let columnWidth: CGFloat = 720

    var body: some View {
        if vm.messages.isEmpty && !vm.isStreaming {
            emptyState
        } else {
            conversation
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if vm.memorySummary != nil || !vm.pinnedFacts.isEmpty { memoryBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.x8) {
                        ForEach(vm.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if vm.isStreaming { streamingRow.id("streaming") }
                    }
                    .frame(maxWidth: columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Space.x8)
                    .padding(.vertical, DS.Space.x10)
                }
                // Open at the latest message (bottom), not the top of the history.
                .defaultScrollAnchor(.bottom)
                .onChange(of: vm.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: vm.streamingText) { _, _ in scrollToBottom(proxy) }
                // Switching threads (or returning to the tab) jumps to the newest turn.
                .onChange(of: vm.messages.last?.id) { _, _ in scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }

            if !vm.isStreaming, let last = vm.messages.last, last.role == .assistant {
                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    if ConfirmationHints.isPendingConfirmation(last.content) { approveBar }
                    if let fact = pinSuggestion { pinChip(fact) }
                    followups(for: last)
                }
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Space.x8)
            }
            askBar
        }
        .task { await vm.loadMemorySummary() }
    }

    /// A quiet memory pill: shows pinned-fact count and (when older turns were
    /// summarized) a "compacted" marker + live context usage. Tap for details.
    private var memoryBar: some View {
        let est = vm.contextEstimate
        let pins = vm.pinnedFacts.count
        let compacted = vm.memorySummary != nil
        return HStack {
            Spacer()
            Button { showMemory.toggle() } label: {
                HStack(spacing: DS.Space.x1) {
                    Image(systemName: "sparkles").font(.system(size: 9))
                    if pins > 0 { Text("\(pins) remembered").font(DS.Typo.caption) }
                    if compacted {
                        Text(pins > 0 ? "· compacted" : "Memory compacted").font(DS.Typo.caption)
                    }
                    Text("· ~\(ContextManager.humanTokens(est.used))/\(ContextManager.humanTokens(est.budget)) ctx")
                        .font(DS.Typo.mono)
                    Image(systemName: "info.circle").font(.system(size: 9))
                }
                .foregroundStyle(DS.ColorToken.textTertiary)
                .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                .overlay(Capsule().strokeBorder(DS.ColorToken.borderSubtle, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMemory, arrowEdge: .top) { memoryPopover }
            Spacer()
        }
        .padding(.top, DS.Space.x3)
    }

    private var memoryPopover: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            if !vm.pinnedFacts.isEmpty {
                Text("LONG-TERM MEMORY").font(DS.Typo.caption).tracking(1)
                    .foregroundStyle(DS.ColorToken.textTertiary)
                ForEach(vm.pinnedFacts, id: \.self) { fact in
                    HStack(alignment: .top, spacing: DS.Space.x2) {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(DS.ColorToken.iris)
                        Text(fact).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let summary = vm.memorySummary, !summary.isEmpty {
                if !vm.pinnedFacts.isEmpty { Divider().overlay(DS.ColorToken.borderSubtle) }
                Text("EARLIER CONVERSATION").font(DS.Typo.caption).tracking(1)
                    .foregroundStyle(DS.ColorToken.textTertiary)
                Text(summary).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button { showMemory = false; Task { await vm.forgetMemory() } } label: {
                    HStack(spacing: DS.Space.x1) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("Forget this summary").font(DS.Typo.caption)
                    }.foregroundStyle(DS.ColorToken.textTertiary)
                }.buttonStyle(.plain).help("Clear the stored summary; the next turn recompacts from scratch.")
            }
        }
        .padding(DS.Space.x4).frame(width: 360)
    }

    @ViewBuilder
    private func followups(for message: ChatMessage) -> some View {
        let question = vm.messages.dropLast().last(where: { $0.role == .user })?.content ?? ""
        let suggestions = FollowupSuggester.followups(question: question, answer: message.content,
                                                      citations: message.citations)
        if !suggestions.isEmpty {
            HStack(spacing: DS.Space.x2) {
                Text("NEXT").font(DS.Typo.caption).tracking(1.2)
                    .foregroundStyle(DS.ColorToken.textTertiary)
                    .fixedSize()
                ForEach(suggestions, id: \.self) { s in
                    Button { vm.send(s.send) } label: {
                        HStack(spacing: DS.Space.x2) {
                            Image(systemName: s.icon).font(.system(size: 10))
                                .foregroundStyle(s.isAction ? DS.ColorToken.iris : DS.ColorToken.textTertiary)
                            Text(s.label).font(DS.Typo.callout)
                                .foregroundStyle(s.isAction ? DS.ColorToken.textPrimary : DS.ColorToken.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
                        .background(s.isAction ? DS.ColorToken.iris.opacity(0.08) : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(
                            s.isAction ? DS.ColorToken.iris.opacity(0.35) : DS.ColorToken.borderDefault, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, DS.Space.x3)
        }
    }

    private var askBar: some View {
        OmniPrompt(text: $draft, isBusy: vm.isStreaming, focusRequest: focusBump,
                   onSend: send, onStop: vm.cancel)
            .frame(maxWidth: columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Space.x8)
            .padding(.bottom, DS.Space.x8).padding(.top, DS.Space.x4)
            .background {
                Button("") { focusBump += 1 }.keyboardShortcut("k", modifiers: .command).opacity(0)
            }
    }

    /// Seed the prompt with a query and send it (used by "Ask about this").
    func seed(_ text: String) { vm.send(text) }

    private func send() {
        let text = draft
        draft = ""
        vm.send(text)
    }

    // AI-first hero: the ask field is the centre of gravity. Airy, Swiss, one accent.
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: DS.Space.x4) {
                Text("Ask your Mac.")
                    .font(DS.Typo.hero).tracking(-1.5)
                    .foregroundStyle(DS.ColorToken.textPrimary)
                Text("Everything you've saved — files, notes, PDFs, images, code — answerable, with sources.")
                    .font(DS.Typo.title2).fontWeight(.regular)
                    .foregroundStyle(DS.ColorToken.textTertiary)
                    .frame(maxWidth: 560, alignment: .leading)

                OmniPrompt(text: $draft, isBusy: vm.isStreaming, focusRequest: focusBump,
                           onSend: send, onStop: vm.cancel,
                           onFocusChange: { composerFocused = $0; updateMotes() })
                    .padding(.top, DS.Space.x4)
                    .background {
                        Button("") { focusBump += 1 }.keyboardShortcut("k", modifiers: .command).opacity(0)
                    }

                suggestionChips.padding(.top, DS.Space.x2)
            }
            .frame(maxWidth: 640)
            Spacer()
            Spacer()
            Button(action: onIngest) {
                Text("Ingest a folder to begin  ↗").font(DS.Typo.callout)
                    .foregroundStyle(DS.ColorToken.iris)
            }.buttonStyle(.plain).padding(.bottom, DS.Space.x10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.Space.x10)
        .background(AmbientMotesField(energy: motesEnergy, focal: UnitPoint(x: 0.5, y: 0.46)))
        .onChange(of: draft) { _, _ in updateMotes() }
    }

    /// Autonomous, content-derived suggestions — tap to run them.
    private var suggestionChips: some View {
        FlowLayout(spacing: DS.Space.x2) {
            ForEach(vm.suggestions) { s in
                Button { vm.send(s.query) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.icon).font(.system(size: 11))
                            .foregroundStyle(DS.ColorToken.iris)
                        Text(s.title).font(DS.Typo.callout)
                            .foregroundStyle(DS.ColorToken.textSecondary)
                    }
                    .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x2)
                    .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(s.query)
            }
        }
        .task { await vm.loadSuggestions() }
    }

    /// A live view of what the agent is doing this turn — the plan (as a checklist
    /// that fills in) and a running trace of tool activity. Transparent, Claude-Code-style.
    private var agentActivityPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            HStack(spacing: DS.Space.x3) {
                ThinkingIndicator()
                let line = vm.agentStatus.isEmpty ? String(vm.streamingReasoning.suffix(70)) : vm.agentStatus
                if !line.isEmpty {
                    Text(line.replacingOccurrences(of: "\n", with: " "))
                        .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary).lineLimit(1)
                }
            }
            if !vm.agentPlan.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PLAN").font(DS.Typo.caption).tracking(1).foregroundStyle(DS.ColorToken.textTertiary)
                    ForEach(Array(vm.agentPlan.enumerated()), id: \.offset) { i, step in
                        let done = i < vm.completedSteps
                        let active = i == vm.completedSteps && vm.isStreaming
                        HStack(alignment: .top, spacing: DS.Space.x2) {
                            Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.dotted" : "circle"))
                                .font(.system(size: 11))
                                .foregroundStyle(done ? DS.ColorToken.success : (active ? DS.ColorToken.iris : DS.ColorToken.textTertiary))
                            Text(step).font(DS.Typo.callout)
                                .foregroundStyle(done ? DS.ColorToken.textTertiary : DS.ColorToken.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(DS.Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }
            if !vm.agentTrace.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(vm.agentTrace.suffix(4).enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                                .foregroundStyle(DS.ColorToken.iris.opacity(0.7))
                            Text(t.replacingOccurrences(of: "\n", with: " "))
                                .font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .assistant {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                if !message.reasoning.isEmpty { reasoningTrace(message.reasoning, id: message.id) }
                AnswerCardView(
                    message: message,
                    isLast: message.id == vm.messages.last?.id && !vm.isStreaming,
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.copyableText, forType: .string)
                    },
                    onRegenerate: { vm.regenerateLast() },
                    onReveal: { reveal($0) })
                if !message.agentNote.isEmpty {
                    HStack(spacing: DS.Space.x1) {
                        Image(systemName: "info.circle").font(.system(size: 9))
                        Text(message.agentNote).font(DS.Typo.caption)
                    }
                    .foregroundStyle(DS.ColorToken.textTertiary)
                    .padding(.leading, DS.Space.x1)
                }
            }
        } else {
            ChatBubble(role: .user) { Text(message.content).textSelection(.enabled) }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @State private var expandedReasoning: Set<UUID> = []

    private func reasoningTrace(_ text: String, id: UUID) -> some View {
        let shown = expandedReasoning.contains(id)
        return VStack(alignment: .leading, spacing: DS.Space.x2) {
            Button {
                if shown { expandedReasoning.remove(id) } else { expandedReasoning.insert(id) }
            } label: {
                HStack(spacing: DS.Space.x2) {
                    Text("REASONING").font(DS.Typo.caption).tracking(1.2)
                    Image(systemName: shown ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }
                .foregroundStyle(DS.ColorToken.textTertiary)
            }.buttonStyle(.plain)
            if shown {
                Text(text).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                    .textSelection(.enabled).lineSpacing(2)
                    .padding(DS.Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.ColorToken.canvasRaised,
                                in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(DS.ColorToken.borderSubtle, lineWidth: 1))
            }
        }
        .padding(.leading, DS.Space.x8)
    }

    // The answer forming — same Swiss card shell (white, hairline, accent rule).
    private var streamingRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            Text("ANSWER").font(DS.Typo.caption).tracking(1.5)
                .foregroundStyle(DS.ColorToken.iris)
            if vm.streamingText.isEmpty {
                agentActivityPanel
            } else {
                Text(vm.streamingText).font(.system(size: 15.5, weight: .regular, design: .serif))
                    .foregroundStyle(DS.ColorToken.textPrimary).lineSpacing(2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.x6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.ColorToken.iris).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    /// Open the cited source — a web link in the browser, a file in Finder.
    private func reveal(_ citation: Citation) {
        if citation.path.lowercased().hasPrefix("http"), let web = URL(string: citation.path) {
            NSWorkspace.shared.open(web); return
        }
        let url = URL(fileURLWithPath: citation.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        func jump() {
            if vm.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = vm.messages.last?.id {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
        if animated { withAnimation(DS.Motion.base) { jump() } } else { jump() }
    }
}
