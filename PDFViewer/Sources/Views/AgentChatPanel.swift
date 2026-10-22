import AppKit
import SwiftUI

struct AgentChatPanel: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var model: AgentChatModel

    @State private var showSettings = false
    @State private var copiedLog = false
    @State private var isNearBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var contentBottom: CGFloat = 0
    @State private var inputFocused = false

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
        .background(shortcutButtons)
    }

    /// Invisible buttons that provide Esc (stop) and ⌘⇧C (copy last reply).
    private var shortcutButtons: some View {
        Group {
            Button("Stop generating") { model.stop() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Copy last reply") { copyLastAssistant() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func copyLastAssistant() {
        guard let reply = model.messages.last(where: { $0.role == .assistant }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reply.text, forType: .string)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text("opencode")
                    .font(.system(size: 13, weight: .semibold))
                statusBadge
            }

            Spacer()

            headerButton("square.and.pencil", help: "Start a new conversation") {
                model.newChat()
            }
            .disabled(model.messages.isEmpty)

            headerButton("gearshape", help: "Connection settings") {
                showSettings.toggle()
            }

            headerButton("sidebar.right", help: "Hide the agent panel") {
                store.showAgentPanel = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.bar)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverTint()
        .help(help)
    }

    private var statusBadge: some View {
        Button {
            Task { await model.connect() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(model.status.shortLabel)
                    .font(.system(size: 10))
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        emptyState
                    }

                    ForEach(model.messages) { message in
                        ChatBubble(
                            message: message,
                            canInsertIntoNote: store.selectedNoteTab != nil || store.notes.isEmpty == false,
                            onRegenerate: { Task { await model.regenerate() } },
                            onDelete: { model.delete(message) },
                            onInsertIntoNote: { insertIntoNote(message.text) }
                        )
                        .id(message.id)
                    }

                    if model.isSending {
                        thinkingRow.id("thinking")
                    }

                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: BottomEdgeKey.self,
                                    value: geo.frame(in: .named("agentScroll")).maxY
                                )
                            }
                        )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "agentScroll")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(BottomEdgeKey.self) { value in
                contentBottom = value
                updateNearBottom()
            }
            .onPreferenceChange(ViewportKey.self) { value in
                viewportHeight = value
                updateNearBottom()
            }
            .overlay(alignment: .bottomTrailing) {
                if !isNearBottom, !model.messages.isEmpty {
                    Button {
                        scrollToEnd(proxy)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                if isNearBottom { scrollToEnd(proxy) }
            }
            .onChange(of: model.isSending) { _, _ in
                if isNearBottom { scrollToEnd(proxy) }
            }
        }
    }

    private func updateNearBottom() {
        guard viewportHeight > 0 else { return }
        isNearBottom = contentBottom <= viewportHeight + 40
    }

    private func insertIntoNote(_ text: String) {
        let note: NoteTab
        if let existing = store.selectedNoteTab {
            note = existing
        } else {
            note = store.newNote()
        }
        let combined = NSMutableAttributedString(attributedString: note.text)
        if combined.length > 0 {
            combined.append(NSAttributedString(string: "\n\n"))
        }
        combined.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        note.text = combined
        note.markChanged()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.opacity(0.10)))

            Text("Ask about this document")
                .font(.system(size: 14, weight: .semibold))

            Text(
                "Choose the context, then ask a question. Select “Whole workbook” to search across everything in your workbook."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
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
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 18)
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
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty {
                attachmentChips
            }

            ZStack(alignment: .topLeading) {
                CommandLineField(
                    text: $model.input,
                    onSubmit: { send() },
                    onPrevious: { model.recallPrevious() },
                    onNext: { model.recallNext() },
                    onEdited: { model.resetHistoryCursor() },
                    onFocusChange: { inputFocused = $0 }
                )

                if model.input.isEmpty {
                    Text("Ask about this document…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Button {
                    let urls = pickFiles()
                    if !urls.isEmpty { model.addAttachments(from: urls) }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach files")

                contextChip

                Spacer(minLength: 4)

                if !model.modelLabel.isEmpty {
                    Text(model.modelLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                sendButton
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    inputFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.10),
                    lineWidth: inputFocused ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.12), value: inputFocused)
    }

    private var contextChip: some View {
        Menu {
            ForEach(AgentChatModel.ContextScope.allCases) { scope in
                Button {
                    model.contextScope = scope
                } label: {
                    Label(scope.label, systemImage: contextSymbol(scope))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: contextSymbol(model.contextScope))
                    .font(.system(size: 11))
                Text(contextShortLabel(model.contextScope))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Context: \(model.contextScope.label)")
    }

    private var sendButton: some View {
        Button {
            if model.isSending {
                model.stop()
            } else {
                send()
            }
        } label: {
            Image(systemName: model.isSending ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        (model.isSending || model.canSend) ? Color.accentColor : Color.secondary.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!model.isSending && !model.canSend)
        .help(model.isSending ? "Stop" : "Send")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachmentSymbol(attachment.kind))
                            .font(.system(size: 10))
                        Text(attachment.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(byteString(attachment.size))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Button {
                            model.removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func attachmentSymbol(_ kind: AgentChatModel.Attachment.Kind) -> String {
        switch kind {
        case .pdf: return "doc.text"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func contextSymbol(_ scope: AgentChatModel.ContextScope) -> String {
        switch scope {
        case .wholeDocument: return "doc.text"
        case .workbook: return "books.vertical"
        case .currentPage: return "doc"
        case .none: return "slash.circle"
        }
    }

    private func contextShortLabel(_ scope: AgentChatModel.ContextScope) -> String {
        switch scope {
        case .wholeDocument: return "Document"
        case .workbook: return "Workbook"
        case .currentPage: return "Page"
        case .none: return "No context"
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

            HStack(spacing: 6) {
                TextField("Quiz folder", text: $model.quizFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Choose…") {
                    model.chooseQuizFolder()
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
        let context = contextForScope(query: model.input)
        Task { await model.send(context: context) }
    }

    private func contextForScope(query: String) -> String? {
        switch model.contextScope {
        case .none:
            return nil
        case .workbook:
            return AgentChatModel.workbookContext(query: query, focusPath: store.activeTab?.url.path)
        case .currentPage, .wholeDocument:
            guard let tab = store.activeTab else { return nil }
            return AgentChatModel.context(for: tab, scope: model.contextScope)
        }
    }
}

private struct BottomEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A single message with hover actions (copy, regenerate, insert into note,
/// delete) and selectable text.
private struct ChatBubble: View {
    let message: AgentChatModel.ChatMessage
    var canInsertIntoNote: Bool
    var onRegenerate: () -> Void
    var onDelete: () -> Void
    var onInsertIntoNote: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
            } else {
                Image(systemName: message.role == .error ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(message.role == .error ? Color.red : Color.accentColor)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill((message.role == .error ? Color.red : Color.accentColor).opacity(0.12))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                if message.attachedContext != nil {
                    Label("Context attached", systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                switch message.role {
                case .assistant:
                    MathOrMarkdown(markdown: message.text)
                case .user:
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                case .error:
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .foregroundStyle(.red)
                }

                if hovering || copied {
                    actionRow
                }
            }
            .padding(message.role == .user ? 10 : 0)
            .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
            .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .onHover { hovering = $0 }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            action(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy", copy)

            if message.role == .assistant {
                action("arrow.clockwise", "Regenerate", onRegenerate)
                if canInsertIntoNote {
                    action("note.text", "Insert into note", onInsertIntoNote)
                }
            }

            action("trash", "Delete", onDelete)
        }
        .transition(.opacity)
    }

    private func action(_ symbol: String, _ help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// A command-line style text field: Return submits, Shift+Return inserts a
/// newline, and the up/down arrows recall previous inputs.
struct CommandLineField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onEdited: () -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

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
        textView.textContainerInset = NSSize(width: 8, height: 3)
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

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }
    }
}

final class CommandLineTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private let minHeight: CGFloat = 18
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
        case 36, 76:  // Return, keypad Enter
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
        case 126:  // Up arrow
            if string.isEmpty || selectedRange().location == 0 {
                onPrevious?()
            } else {
                super.keyDown(with: event)
            }
        case 125:  // Down arrow
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
                case .code(let code, let language):
                    CodeBlock(code: code, language: language)
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
    let language: String?

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
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
    case code(String, language: String?)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?
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
                blocks.append(.code(code.joined(separator: "\n"), language: language))
            }
            code.removeAll()
            language = nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}
