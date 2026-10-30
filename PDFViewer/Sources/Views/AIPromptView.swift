import AppKit
import SwiftUI

/// A compact, resizable floating prompt for the opencode agent.
struct AIPromptView: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var agent: AgentChatModel
    @EnvironmentObject private var store: LibraryStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if !agent.status.isConnected {
                await agent.connect()
            }
        }
        .onAppear { focused = true }
        .hotReload()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text("AI")
                .font(.headline)
            Text(agent.status.shortLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(AgentChatModel.ContextScope.allCases) { scope in
                    Button {
                        agent.contextScope = scope
                    } label: {
                        if agent.contextScope == scope {
                            Label(scope.label, systemImage: "checkmark")
                        } else {
                            Text(scope.label)
                        }
                    }
                }
            } label: {
                Label(agent.contextScope.label, systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Context sent with each prompt")

            Spacer()

            if agent.isSending {
                ProgressView()
                    .controlSize(.small)
            }

            if !agent.messages.isEmpty {
                Button {
                    agent.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New conversation")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.messages.isEmpty {
                        Text("Ask anything…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    }

                    ForEach(Array(agent.messages.suffix(50))) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: agent.isSending) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: AgentChatModel.ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        case .assistant:
            MathOrMarkdown(markdown: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything…", text: $agent.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)

            if agent.isSending {
                Button {
                    agent.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .disabled(agent.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(10)
    }

    private func send() {
        guard !agent.isSending else { return }
        let query = agent.input
        let context = contextForScope(query: query)
        Task { await agent.send(context: context) }
    }

    private func contextForScope(query: String) -> String? {
        switch agent.contextScope {
        case .none:
            return nil
        case .workbook:
            return AgentChatModel.workbookContext(
                query: query,
                focusPath: store.activeTab?.url.path
            )
        case .currentPage, .wholeDocument:
            guard let tab = store.activeTab else { return nil }
            return AgentChatModel.context(for: tab, scope: agent.contextScope)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = agent.messages.last else { return }
        withAnimation {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
