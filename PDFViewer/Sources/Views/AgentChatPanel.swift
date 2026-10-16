import AppKit
import SwiftUI

struct AgentChatPanel: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var model: AgentChatModel

    @State private var showSettings = false
    @State private var copiedLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if !model.status.isConnected {
                await model.connect()
            }
        }
        .onChange(of: model.messages.last?.id) { _, _ in
            if model.messages.last?.role == .error {
                showSettings = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)

            Text("opencode")
                .font(.headline)

            statusBadge

            Spacer()

            Button {
                model.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("Start a new conversation")
            .disabled(model.messages.isEmpty)

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Connection settings")

            Button {
                store.showAgentPanel = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
            .help("Hide the agent panel")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var statusBadge: some View {
        Button {
            Task { await model.connect() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.status.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Reconnect to the opencode server")
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected, .failed: return .secondary
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        emptyState
                    }

                    ForEach(model.messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }

                    if model.isSending {
                        thinkingRow.id("thinking")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.isSending) { _, _ in scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this document")
                .font(.callout.weight(.semibold))
            Text("Attach the context you want considered, then ask a question. Select “Whole document” to let opencode reference the entire PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func bubble(for message: AgentChatModel.ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                if message.attachedContext != nil {
                    Label("Context attached", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                switch message.role {
                case .assistant:
                    MathOrMarkdown(markdown: message.text)
                case .user:
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                case .error:
                    Label(message.text, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .padding(message.role == .assistant ? 0 : 10)
            .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
            .background(message.role == .assistant ? Color.clear : bubbleBackground(for: message.role))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(message.role == .error ? Color.red : Color.primary)

            if message.role != .user {
                Spacer(minLength: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func bubbleBackground(for role: AgentChatModel.ChatMessage.Role) -> Color {
        switch role {
        case .user:
            return Color.accentColor.opacity(0.16)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor)
        case .error:
            return Color.red.opacity(0.12)
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("opencode is thinking…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if model.isSending {
            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
        } else if let last = model.messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if model.status.isConnected && !showSettings {
                composer
            } else {
                settings
                if !model.logs.isEmpty {
                    logConsole
                }
            }
        }
        .padding(12)
    }

    private var logConsole: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Connection log")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.status == .connecting {
                    ProgressView().controlSize(.mini)
                }
                Button(copiedLog ? "Copied" : "Copy") {
                    if model.copyLogs() {
                        copiedLog = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLog = false }
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(copiedLog ? Color.green : Color.secondary)
                .help("Copy the full log to the clipboard")

                Button("Clear") {
                    model.clearLogs()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.time)
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logs.count) { _, _ in
                    if let last = model.logs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(height: 110)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Context", selection: $model.contextScope) {
                    ForEach(AgentChatModel.ContextScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    CommandLineField(
                        text: $model.input,
                        onSubmit: { send() },
                        onPrevious: { model.recallPrevious() },
                        onNext: { model.recallNext() },
                        onEdited: { model.resetHistoryCursor() }
                    )

                    if model.input.isEmpty {
                        Text("Ask a question about this document…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .help("Send")
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let message) = model.status {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.status.isConnected {
                Label(model.status.shortLabel, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not connected to opencode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("http://127.0.0.1:4096", text: $model.serverAddress)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            TextField("Model (provider/model, optional)", text: $model.modelOverride)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            HStack(spacing: 6) {
                TextField("Flashcard folder", text: $model.flashcardFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Choose…") {
                    model.chooseFlashcardFolder()
                }
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                TextField("Summary folder", text: $model.summaryFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Choose…") {
                    model.chooseSummaryFolder()
                }
                .controlSize(.small)
            }

            HStack {
                Button("Connect") {
                    Task { await model.connect() }
                }

                Button("Test connection") {
                    Task { await model.testConnection() }
                }

                Button("Start server") {
                    Task { await model.startServer() }
                }

                Spacer()

                if model.status.isConnected {
                    Button("Done") {
                        showSettings = false
                    }
                }
            }
            .controlSize(.small)
            .disabled(model.status == .connecting)

            Text("Needs `opencode serve` running. The model uses the server default when left blank.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func send() {
        let context = contextForScope()
        Task { await model.send(context: context) }
    }

    private func contextForScope() -> String? {
        guard let tab = store.activeTab else { return nil }
        return AgentChatModel.context(for: tab, scope: model.contextScope)
    }
}

/// A command-line style text field: Return submits, Shift+Return inserts a
/// newline, and the up/down arrows recall previous inputs.
private struct CommandLineField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onEdited: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CommandLineTextView {
        let textView = CommandLineTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        applyCallbacks(to: textView)
        context.coordinator.textView = textView
        return textView
    }

    func updateNSView(_ textView: CommandLineTextView, context: Context) {
        context.coordinator.parent = self
        applyCallbacks(to: textView)
        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.invalidateIntrinsicContentSize()
        }
    }

    private func applyCallbacks(to textView: CommandLineTextView) {
        textView.onSubmit = onSubmit
        textView.onPrevious = onPrevious
        textView.onNext = onNext
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandLineField
        weak var textView: CommandLineTextView?

        init(_ parent: CommandLineField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CommandLineTextView else { return }
            parent.text = textView.string
            parent.onEdited()
        }
    }
}

private final class CommandLineTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let minHeight: CGFloat = 32
    private let maxHeight: CGFloat = 148
    private var lastMeasuredWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
        case 126: // Up arrow
            if string.isEmpty || selectedRange().location == 0 {
                onPrevious?()
            } else {
                super.keyDown(with: event)
            }
        case 125: // Down arrow
            if selectedRange().location >= (string as NSString).length {
                onNext?()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func measuredHeight() -> CGFloat {
        guard let layoutManager, let textContainer else { return minHeight }
        lastMeasuredWidth = bounds.width
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        return min(max(used + textContainerInset.height * 2, minHeight), maxHeight)
    }
}

/// Renders markdown, honoring inline formatting and fenced code blocks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code):
                    CodeBlock(code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func attributed(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}

private struct CodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

private enum MarkdownBlock {
    case prose(String)
    case code(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var inCode = false

        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.prose(joined))
            }
            prose.removeAll()
        }

        func flushCode() {
            if !code.isEmpty {
                blocks.append(.code(code.joined(separator: "\n")))
            }
            code.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}
