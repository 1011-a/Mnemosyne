import SwiftUI

/// The conversational surface. Streams grounded answers and shows citations.
struct ChatView: View {
    @Bindable var vm: ChatViewModel
    var onIngest: () -> Void = {}
    @State private var draft = ""
    @State private var focusBump = 0

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
                .onChange(of: vm.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: vm.streamingText) { _, _ in scrollToBottom(proxy) }
            }

            if !vm.isStreaming, let last = vm.messages.last, last.role == .assistant {
                followups(for: last)
                    .frame(maxWidth: columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Space.x8)
            }
            askBar
        }
    }

    @ViewBuilder
    private func followups(for message: ChatMessage) -> some View {
        let question = vm.messages.dropLast().last(where: { $0.role == .user })?.content ?? ""
        let suggestions = FollowupSuggester.suggest(question: question, citations: message.citations)
        if !suggestions.isEmpty {
            HStack(spacing: DS.Space.x2) {
                Text("FOLLOW UP").font(DS.Typo.caption).tracking(1.2)
                    .foregroundStyle(DS.ColorToken.textTertiary)
                    .fixedSize()
                ForEach(suggestions, id: \.self) { s in
                    Button { vm.send(s) } label: {
                        HStack(spacing: DS.Space.x2) {
                            Text(s).font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.system(size: 9))
                                .foregroundStyle(DS.ColorToken.iris)
                        }
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
                        .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
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
                           onSend: send, onStop: vm.cancel)
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
    }

    private let suggestions = ["Summarize what I saved this week",
                               "What are my notes on …?",
                               "Find that PDF about …"]
    private var suggestionChips: some View {
        HStack(spacing: DS.Space.x2) {
            ForEach(suggestions, id: \.self) { s in
                Button { draft = s } label: {
                    Text(s).font(DS.Typo.callout)
                        .foregroundStyle(DS.ColorToken.textSecondary)
                        .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x2)
                        .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
                }
                .buttonStyle(.plain)
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
                HStack(spacing: DS.Space.x3) {
                    ThinkingIndicator()
                    if !vm.agentStatus.isEmpty {
                        Text(vm.agentStatus).font(DS.Typo.caption)
                            .foregroundStyle(DS.ColorToken.textTertiary).lineLimit(1)
                    } else if !vm.streamingReasoning.isEmpty {
                        Text(String(vm.streamingReasoning.suffix(70)))
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary).lineLimit(1)
                    }
                }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(DS.Motion.base) {
            if vm.isStreaming {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = vm.messages.last?.id {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }
}
