import SwiftUI

/// A full-area assistant that answers using the whole workbook and cites where
/// it found the information.
struct WorkbookChatView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var agent: AgentChatModel
    @EnvironmentObject private var workbooks: WorkbookStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var activeWorkbook: Workbook? {
        guard let id = workbooks.activeWorkbookID else { return nil }
        return workbooks.workbooks.first { $0.id == id }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Workbook Assistant")
                    .font(.headline)
                if let name = activeWorkbook?.name {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                agent.newWorkbookChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("New conversation")
            .disabled(agent.workbookMessages.isEmpty)

            Button {
                store.showWorkbookChat = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close the assistant")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if activeWorkbook == nil {
                        hint("Open a workbook in the Library to use the assistant.")
                    } else if agent.workbookMessages.isEmpty {
                        hint("Ask anything about your workbook — answers quote where the information came from.")
                    }

                    ForEach(agent.workbookMessages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }

                    if agent.isSendingWorkbook {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .padding(16)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: agent.workbookMessages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: agent.isSendingWorkbook) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private func bubble(for message: AgentChatModel.ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            switch message.role {
            case .assistant:
                MathOrMarkdown(markdown: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .user:
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .error:
                Label(message.text, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    CommandLineField(
                        text: $agent.workbookInput,
                        onSubmit: { send() },
                        onPrevious: {},
                        onNext: {},
                        onEdited: {}
                    )

                    if agent.workbookInput.isEmpty {
                        Text("How can I help with your workbook?")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 3)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    Spacer()

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .disabled(activeWorkbook == nil || !agent.canSendWorkbook)
                    .help("Send")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .frame(maxWidth: 760)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }

    private func send() {
        Task { await agent.sendWorkbookMessage() }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if agent.isSendingWorkbook {
            withAnimation { proxy.scrollTo("working", anchor: .bottom) }
        } else if let last = agent.workbookMessages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}
