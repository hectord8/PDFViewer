import AppKit
import Foundation
import PDFKit

/// Drives the "Ask opencode" side panel: talks to `opencode serve`, keeps the
/// chat transcript, and attaches the visible PDF page as context.
@MainActor
final class AgentChatModel: ObservableObject {
    static let shared = AgentChatModel()

    struct ChatMessage: Identifiable {
        enum Role: Equatable {
            case user
            case assistant
            case error
        }

        let id = UUID()
        let role: Role
        let text: String
        let attachedContext: String?
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let text: String
    }

    enum ContextScope: String, CaseIterable, Identifiable {
        case wholeDocument
        case workbook
        case currentPage
        case none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .wholeDocument: return "Whole document"
            case .workbook: return "Whole workbook"
            case .currentPage: return "Current page"
            case .none: return "No context"
            }
        }
    }

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected(version: String?)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var shortLabel: String {
            switch self {
            case .disconnected: return "Offline"
            case .connecting: return "Connecting…"
            case .connected(let version): return version.map { "opencode \($0)" } ?? "Connected"
            case .failed: return "Offline"
            }
        }
    }

    @Published var messages: [ChatMessage] = []
    struct Attachment: Identifiable, Equatable {
        enum Kind { case pdf, text, image, other }
        let id = UUID()
        let name: String
        let kind: Kind
        let size: Int
        var text: String?
    }

    @Published var attachments: [Attachment] = []
    private var lastPrompt: String?

    @Published var input: String = ""
    @Published var contextScope: ContextScope = .wholeDocument {
        didSet { UserDefaults.standard.set(contextScope.rawValue, forKey: Self.scopeKey) }
    }
    @Published var status: Status = .disconnected
    @Published var isSending = false
    @Published var logs: [LogEntry] = []
    @Published var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.addressKey) }
    }
    @Published var modelOverride: String {
        didSet { UserDefaults.standard.set(modelOverride, forKey: Self.modelKey) }
    }
    @Published private(set) var availableModels: [String] = []
    @Published var flashcardFolder: String {
        didSet {
            UserDefaults.standard.set(flashcardFolder, forKey: Self.flashcardFolderKey)
            refreshSavedDecks()
        }
    }
    @Published private(set) var savedDecks: [SavedDeck] = []

    @Published var summaryFolder: String {
        didSet {
            UserDefaults.standard.set(summaryFolder, forKey: Self.summaryFolderKey)
            refreshSavedSummaries()
        }
    }
    @Published private(set) var savedSummaries: [SavedSummary] = []

    @Published var quizFolder: String {
        didSet {
            UserDefaults.standard.set(quizFolder, forKey: Self.quizFolderKey)
            refreshSavedQuizzes()
        }
    }
    @Published private(set) var savedQuizzes: [SavedQuiz] = []

    private static let addressKey = "openCodeServerAddress"
    private static let modelKey = "openCodeModelOverride"
    private static let flashcardFolderKey = "flashcardFolder"
    private static let summaryFolderKey = "summaryFolder"
    private static let quizFolderKey = "quizFolder"
    private static let scopeKey = "contextScope"

    private let library = LibraryStore.shared
    private let workbooks = WorkbookStore.shared

    private var sessionID: String?
    private var client: OpenCodeClient?
    private var serverProcess: Process?
    private var serverLogPipe: Pipe?
    private var serverPort: Int?
    private var serverUsername: String?
    private var serverPassword: String?

    private var history: [String] = []
    private var historyCursor = 0
    private var historyDraft = ""
    private var sentContextHash: Int?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let defaultModel = ""

    private init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.addressKey) ?? "http://127.0.0.1:4096"
        modelOverride = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel
        flashcardFolder = UserDefaults.standard.string(forKey: Self.flashcardFolderKey) ?? Self.defaultFlashcardFolder
        summaryFolder = UserDefaults.standard.string(forKey: Self.summaryFolderKey) ?? Self.defaultSummaryFolder
        quizFolder = UserDefaults.standard.string(forKey: Self.quizFolderKey) ?? Self.defaultQuizFolder
        if let raw = UserDefaults.standard.string(forKey: Self.scopeKey),
            let scope = ContextScope(rawValue: raw)
        {
            contextScope = scope
        }
    }

    private static var defaultFlashcardFolder: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/PDFViewer/Flashcards")
    }

    private static var defaultSummaryFolder: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/PDFViewer/Summaries")
    }

    private static var defaultQuizFolder: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/PDFViewer/Quizzes")
    }

    /// Short model name for the composer label (the part after the provider).
    var modelLabel: String {
        let value = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = value.lastIndex(of: "/") else { return value }
        return String(value[value.index(after: slash)...])
    }

    var canSend: Bool {
        status.isConnected && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    // MARK: - Connection

    func connect() async {
        guard let url = Self.normalizedURL(from: serverAddress) else {
            status = .failed("Enter an address like http://127.0.0.1:4096")
            log("Invalid server address.")
            return
        }

        status = .connecting
        log("Connecting to \(url.absoluteString)…")

        let candidate = Self.makeClient(for: url)
        do {
            let health = try await candidate.health()
            client = candidate
            status = .connected(version: health.version)
            log(health.version.map { "Connected — opencode \($0)" } ?? "Connected.")
            await refreshModels()
        } catch {
            let unreachable = (error as? OpenCodeClient.ClientError)?.kind == .unreachable
            if unreachable, Self.isLocal(url) {
                log("No server responded — starting one…")
                await startServer()
                return
            }
            client = nil
            status = .failed(Self.describe(error))
            log("Connection failed — \(Self.describe(error))")
        }
    }

    /// Checks the address without disturbing an existing connection on failure.
    func testConnection() async {
        guard let url = Self.normalizedURL(from: serverAddress) else {
            log("Can’t test — enter an address like http://127.0.0.1:4096")
            return
        }

        log("Testing \(url.absoluteString)…")

        let probe = Self.makeClient(for: url)
        do {
            let health = try await probe.health()
            client = probe
            status = .connected(version: health.version)
            log("Test OK — healthy: \(health.healthy), version: \(health.version ?? "unknown")")
            await refreshModels()
        } catch {
            log("Test failed — \(Self.describe(error))")
        }
    }

    /// Validates the saved model against the server's provider list and switches
    /// to the server's configured model when the saved one no longer exists.
    private func refreshModels() async {
        guard let client else { return }
        do {
            let models = try await client.availableModels()
            guard !models.isEmpty else { return }
            availableModels = models.sorted()

            let value = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !models.contains(value) else { return }

            let configured = try? await client.configuredModel()
            let provider = value.split(separator: "/").first.map(String.init)
            let sameProvider = provider.flatMap { prefix in
                models.first { $0.hasPrefix(prefix + "/") }
            }
            let fallback =
                configured.flatMap { models.contains($0) ? $0 : nil }
                ?? sameProvider
                ?? models.first
            if let fallback {
                modelOverride = fallback
                log("Model “\(value)” isn’t available — using \(fallback).")
            }
        } catch {
            // The model list is advisory; a failure here shouldn't block chat.
        }
    }

    /// Starts `opencode serve` using a locally installed binary, then connects.
    func startServer() async {
        let url = Self.normalizedURL(from: serverAddress)
        let port = Self.port(from: serverAddress)
        let credentials = url.map { Self.credentials(for: $0) } ?? (username: nil, password: nil)
        let addressMatches =
            serverPort == port
            && serverUsername == credentials.username
            && serverPassword == credentials.password

        if serverProcess?.isRunning == true {
            if addressMatches {
                log("Server already running; connecting…")
                if await probeQuietly() { return }
                log("Server didn’t respond — restarting…")
            } else {
                log("Restarting opencode on port \(port)…")
            }
            stopServer()
        }

        guard let binary = Self.locateOpenCodeBinary() else {
            status = .failed("Couldn’t find the opencode executable. Run `opencode serve` in a terminal, then Connect.")
            log("Couldn’t find the opencode executable.")
            return
        }

        status = .connecting
        log("Starting \(binary.path) serve --port \(port)…")

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "serve",
            "--port", String(port),
            "--hostname", "127.0.0.1",
            "--print-logs",
        ]

        var environment = ProcessInfo.processInfo.environment
        if let username = credentials.username {
            environment["OPENCODE_SERVER_USERNAME"] = username
        }
        if let password = credentials.password {
            environment["OPENCODE_SERVER_PASSWORD"] = password
        }
        process.environment = environment
        serverPort = port
        serverUsername = credentials.username
        serverPassword = credentials.password

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        serverLogPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendServerOutput(text)
            }
        }

        do {
            try process.run()
            serverProcess = process
            log("Started opencode (pid \(process.processIdentifier)).")
        } catch {
            status = .failed("Couldn’t start opencode: \(error.localizedDescription)")
            log("Couldn’t start opencode — \(error.localizedDescription)")
            return
        }

        log("Waiting for the server to come up…")
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await probeQuietly() { return }
        }

        status = .failed("The server didn’t respond. Check the log above.")
        log("Timed out waiting for the server.")
    }

    func stopServer() {
        serverLogPipe?.fileHandleForReading.readabilityHandler = nil
        serverLogPipe = nil
        if let serverProcess, serverProcess.isRunning {
            serverProcess.terminate()
        }
        serverProcess = nil
        serverPort = nil
        serverUsername = nil
        serverPassword = nil
    }

    func clearLogs() {
        logs.removeAll()
    }

    var logsText: String {
        let header = "opencode log — \(serverAddress)\n"
        let body = logs.map { "\($0.time) \($0.text)" }.joined(separator: "\n")
        return header + body
    }

    @discardableResult
    func copyLogs() -> Bool {
        let text = logsText
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    private func probeQuietly() async -> Bool {
        guard let url = Self.normalizedURL(from: serverAddress) else { return false }
        let candidate = Self.makeClient(for: url)
        do {
            let health = try await candidate.health()
            client = candidate
            status = .connected(version: health.version)
            log(health.version.map { "Connected — opencode \($0)" } ?? "Connected.")
            await refreshModels()
            return true
        } catch {
            return false
        }
    }

    private func appendServerOutput(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                log("server: \(trimmed)")
            }
        }
    }

    private func log(_ message: String) {
        logs.append(LogEntry(time: Self.timeFormatter.string(from: Date()), text: message))
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    // MARK: - Chat

    func send(context: String?) async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        guard let client else {
            status = .failed("Not connected to opencode.")
            return
        }

        recordHistory(prompt)
        input = ""
        isSending = true
        defer { isSending = false }

        lastPrompt = prompt
        let attached = Self.merged(context: context, attachments: attachmentContext())
        attachments.removeAll()
        messages.append(ChatMessage(role: .user, text: prompt, attachedContext: attached))

        if Self.looksLikeFlashcards(prompt) {
            await performFlashcards(prompt: prompt, context: attached, client: client)
            return
        }

        if Self.looksLikeAnnotate(prompt) {
            await performAnnotate()
            return
        }

        if Self.looksLikeSummary(prompt) {
            await performSummary(prompt: prompt, context: attached, client: client)
            return
        }

        if Self.looksLikeQuiz(prompt) {
            await performQuiz(prompt: prompt, context: attached, client: client)
            return
        }

        if availableModels.isEmpty {
            await refreshModels()
        }

        let modelName = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        log("Sending request\(modelName.isEmpty ? "" : " (model \(modelName))")…")

        do {
            let session = try await ensureSession(client: client)

            // The session already remembers the conversation, so only attach the
            // (potentially large) context when it's new — cheaper and faster.
            let payload: String
            if let attached, !attached.isEmpty {
                let hash = attached.hashValue
                if sentContextHash == hash {
                    payload = prompt
                } else {
                    sentContextHash = hash
                    payload = Self.compose(question: prompt, context: attached)
                }
            } else {
                payload = prompt
            }

            let reply = try await client.sendMessage(sessionID: session, text: payload, model: parsedModel)
            log("Reply received (\(reply.count) chars).")
            messages.append(
                ChatMessage(
                    role: .assistant,
                    text: reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no response)" : reply,
                    attachedContext: nil
                )
            )
        } catch {
            log("Request failed — \(Self.describe(error))")
            messages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    func newChat() {
        sessionID = nil
        sentContextHash = nil
        lastPrompt = nil
        attachments.removeAll()
        messages.removeAll()
    }

    // MARK: - Quick actions & attachments

    func stop() {
        if let sessionID, let client {
            Task { await client.abort(sessionID: sessionID) }
        }
        if isSending { isSending = false }
        log("Stopped.")
    }

    func delete(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
    }

    /// Re-runs the last prompt (dropping the previous reply).
    func regenerate() async {
        guard let prompt = lastPrompt, let client, !isSending else { return }
        while let last = messages.last, last.role != .user {
            messages.removeLast()
        }
        isSending = true
        defer { isSending = false }
        do {
            let session = try await ensureSession(client: client)
            let reply = try await client.sendMessage(sessionID: session, text: prompt, model: parsedModel)
            messages.append(
                ChatMessage(
                    role: .assistant,
                    text: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachedContext: nil
                )
            )
        } catch {
            messages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    func addAttachments(from urls: [URL]) {
        for url in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let ext = url.pathExtension.lowercased()

            if ext == "pdf", let document = PDFDocument(url: url) {
                var text = ""
                for index in 0..<document.pageCount {
                    if let pageText = document.page(at: index)?.string { text += pageText + "\n" }
                }
                attachments.append(Attachment(name: url.lastPathComponent, kind: .pdf, size: size, text: text))
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                attachments.append(Attachment(name: url.lastPathComponent, kind: .text, size: size, text: text))
            } else if NSImage(contentsOf: url) != nil {
                attachments.append(Attachment(name: url.lastPathComponent, kind: .image, size: size, text: nil))
            } else {
                attachments.append(Attachment(name: url.lastPathComponent, kind: .other, size: size, text: nil))
            }
        }
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func attachmentContext() -> String? {
        let parts = attachments.compactMap { attachment -> String? in
            guard let text = attachment.text else { return nil }
            return "[Attached file: \(attachment.name)]\n\(String(text.prefix(20_000)))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func merged(context: String?, attachments: String?) -> String? {
        switch (context, attachments) {
        case let (context?, attachments?): return context + "\n\n" + attachments
        case let (context?, nil): return context
        case let (nil, attachments?): return attachments
        case (nil, nil): return nil
        }
    }

    // MARK: - Workbook assistant (main chat)

    @Published var workbookMessages: [ChatMessage] = []
    @Published var workbookInput: String = ""
    @Published var isSendingWorkbook = false

    private var workbookSessionID: String?
    private var workbookContextHash: Int?

    var canSendWorkbook: Bool {
        status.isConnected
            && !workbookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSendingWorkbook
    }

    func sendWorkbookMessage() async {
        let prompt = workbookInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSendingWorkbook else { return }
        guard let client else {
            status = .failed("Not connected to opencode.")
            return
        }

        workbookInput = ""
        isSendingWorkbook = true
        defer { isSendingWorkbook = false }
        workbookMessages.append(ChatMessage(role: .user, text: prompt, attachedContext: nil))

        do {
            let session = try await ensureWorkbookSession(client: client)
            let context = Self.workbookContext(query: prompt)

            let payload: String
            if let context, !context.isEmpty {
                let hash = context.hashValue
                if workbookContextHash == hash {
                    payload = prompt
                } else {
                    workbookContextHash = hash
                    payload = Self.workbookAssistantPrompt(question: prompt, context: context)
                }
            } else {
                payload = prompt
            }

            let reply = try await client.sendMessage(sessionID: session, text: payload, model: parsedModel)
            workbookMessages.append(
                ChatMessage(
                    role: .assistant,
                    text: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachedContext: nil
                )
            )
        } catch {
            log("Workbook request failed — \(Self.describe(error))")
            workbookMessages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    func newWorkbookChat() {
        workbookSessionID = nil
        workbookContextHash = nil
        workbookMessages.removeAll()
    }

    private func ensureWorkbookSession(client: OpenCodeClient) async throws -> String {
        if let workbookSessionID { return workbookSessionID }
        let created = try await client.createSession()
        workbookSessionID = created
        return created
    }

    private static func workbookAssistantPrompt(question: String, context: String) -> String {
        """
        You are a study assistant for a whole workbook of course material. Answer the question using the material below. Wherever you use a fact, name the document (and page or heading) it came from and quote the relevant snippet. Finish with a short "Sources" section listing the documents and pages you drew on. If the material doesn't contain the answer, say so.

        [Workbook material]
        \(context)
        [End workbook material]

        Question: \(question)
        """
    }

    // MARK: - Quizzes

    static func looksLikeQuiz(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("test me") || lower.contains("practice questions") {
            return true
        }
        return lower.split(whereSeparator: { !$0.isLetter }).contains("quiz")
    }

    /// Asks opencode for quiz questions, then opens the result as a new tab.
    private func performQuiz(prompt: String, context: String?, client: OpenCodeClient) async {
        log("Quiz request detected — asking opencode for questions…")

        do {
            let session = try await ensureSession(client: client)
            let request = Self.quizGenerationRequest(prompt: prompt, context: context)
            let reply = try await client.sendMessage(sessionID: session, text: request, model: parsedModel)

            guard let quiz = Self.parseQuiz(reply) else {
                log("Couldn’t read quiz JSON — showing the reply as a normal answer.")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachedContext: nil
                    )
                )
                return
            }

            let title = Self.quizTitle(document: library.activeTab?.title, model: quiz.title)
            let savedURL = writeQuiz(title: title, questions: quiz.questions)
            let tab = QuizTab(title: title, questions: quiz.questions, fileURL: savedURL)
            library.openQuiz(tab)
            addToActiveWorkbook(kind: .quiz, title: title, url: savedURL)
            refreshSavedQuizzes()

            log("Created quiz “\(title)” with \(tab.questions.count) questions.")
            messages.append(
                ChatMessage(
                    role: .assistant,
                    text:
                        "Created the quiz “\(title)” with \(tab.questions.count) question\(tab.questions.count == 1 ? "" : "s"). Answer in the new tab, then press “Mark quiz”.",
                    attachedContext: nil
                )
            )
        } catch {
            log("Quiz request failed — \(Self.describe(error))")
            messages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    /// Marks only the questions the reader has answered so far, merging the
    /// results in (so a quiz can be marked without completing every question).
    func mark(_ quiz: QuizTab) async {
        guard !quiz.isMarking else { return }
        let pending = quiz.pending
        guard !pending.isEmpty else { return }

        quiz.isMarking = true
        defer { quiz.isMarking = false }
        log("Marking \(pending.count) answer\(pending.count == 1 ? "" : "s") in “\(quiz.title)”…")

        var results = quiz.results
        var written: [(index: Int, question: QuizQuestion)] = []

        // Multiple-choice questions are graded instantly and locally.
        for entry in pending {
            guard entry.question.kind == .multipleChoice else {
                written.append(entry)
                continue
            }
            let selected = quiz.answers.indices.contains(entry.index - 1) ? quiz.answers[entry.index - 1] : ""
            let correct = Int(selected) == entry.question.correctOptionIndex
            results.removeAll { $0.questionID == entry.question.id }
            results.append(
                QuizResult(
                    questionID: entry.question.id,
                    correct: correct,
                    awarded: correct ? entry.question.marks : 0,
                    feedback: correct ? "" : "Correct answer: \(entry.question.answer)"
                )
            )
        }

        if !written.isEmpty {
            if let client {
                do {
                    let session = try await ensureSession(client: client)
                    let request = Self.quizGradingRequest(quiz: quiz, pending: written)
                    let reply = try await client.sendMessage(sessionID: session, text: request, model: parsedModel)
                    if let graded = Self.parseGrading(reply) {
                        for entry in graded {
                            guard let match = written.first(where: { $0.index == entry.index }) else { continue }
                            let proposed = entry.awarded ?? (entry.correct ? match.question.marks : 0)
                            let awarded = min(max(proposed, 0), match.question.marks)
                            results.removeAll { $0.questionID == match.question.id }
                            results.append(
                                QuizResult(
                                    questionID: match.question.id,
                                    correct: entry.correct,
                                    awarded: awarded,
                                    feedback: entry.feedback
                                )
                            )
                        }
                    } else {
                        log("Couldn’t read the marking result — try again.")
                    }
                } catch {
                    log("Marking written answers failed — \(Self.describe(error))")
                }
            } else {
                log("Can’t mark written answers — not connected to opencode.")
            }
        }

        quiz.results = results
        quiz.marked = !results.isEmpty
        log("Marked \(results.count) answer\(results.count == 1 ? "" : "s").")
    }

    private struct GradedResult {
        let index: Int
        let correct: Bool
        let awarded: Int?
        let feedback: String
    }

    private struct ParsedQuiz {
        let title: String?
        let questions: [QuizQuestion]
    }

    private struct QuizPayload: Decodable {
        struct Item: Decodable {
            let question: String?
            let answer: String?
            let marks: Int?
            let type: String?
            let options: [String]?
        }
        let title: String?
        let questions: [Item]?
    }

    private struct GradePayload: Decodable {
        struct Item: Decodable {
            let index: Int?
            let correct: Bool?
            let awarded: Int?
            let feedback: String?
        }
        let results: [Item]?
    }

    private static func parseQuiz(_ text: String) -> ParsedQuiz? {
        guard let json = jsonObject(in: text), let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(QuizPayload.self, from: data)
        else {
            return nil
        }

        let questions = (payload.questions ?? []).compactMap { item -> QuizQuestion? in
            guard let prompt = item.question?.trimmingCharacters(in: .whitespacesAndNewlines),
                !prompt.isEmpty
            else { return nil }

            let options = (item.options ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let wantsMultipleChoice = item.type?.lowercased().contains("multi") == true && options.count >= 2

            return QuizQuestion(
                prompt: prompt,
                answer: item.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                marks: max(1, item.marks ?? 1),
                kind: wantsMultipleChoice ? .multipleChoice : .open,
                options: wantsMultipleChoice ? options : []
            )
        }

        guard !questions.isEmpty else { return nil }
        return ParsedQuiz(title: payload.title, questions: questions)
    }

    private static func parseGrading(_ text: String) -> [GradedResult]? {
        guard let json = jsonObject(in: text), let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(GradePayload.self, from: data),
            let items = payload.results, !items.isEmpty
        else {
            return nil
        }

        var results: [GradedResult] = []
        for (position, item) in items.enumerated() {
            let index = item.index ?? (position + 1)
            guard index >= 1 else { continue }
            results.append(
                GradedResult(
                    index: index,
                    correct: item.correct ?? false,
                    awarded: item.awarded,
                    feedback: item.feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            )
        }

        return results.isEmpty ? nil : results
    }

    private static func jsonObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start < end
        else { return nil }
        return String(text[start...end])
    }

    private static func quizTitle(document: String?, model: String?) -> String {
        if let document = document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            let base = document.hasSuffix("-quiz") ? String(document.dropLast(5)) : document
            return "\(base)-quiz"
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            return model.hasSuffix("-quiz") ? model : "\(model)-quiz"
        }
        return "quiz"
    }

    private static func quizGenerationRequest(prompt: String, context: String?) -> String {
        var request = """
            Create an exam-style quiz for revising for a final exam, with a mix of multiple-choice and open short-answer questions. Questions should be conceptual, applied and integrative — testing the concepts most likely to be assessed, not notation, formats or trivia. Write any mathematics as LaTeX (inline $...$, display $$...$$); since this is JSON, escape backslashes in LaTeX (write \\frac as \\\\frac). Respond with ONLY valid JSON — no prose, no markdown, no code fences — using exactly this shape:
            {"title": "Quiz title", "questions": [{"question": "The question text", "type": "mc", "options": ["First", "Second", "Third", "Fourth"], "answer": "Second", "marks": 1}, {"question": "Another question", "type": "open", "answer": "A concise model answer used for marking", "marks": 2}]}
            For multiple-choice questions use "type": "mc" with exactly 4 "options" and "answer" set to the exact text of the correct option. For written questions use "type": "open" with a model "answer". Write 5 questions unless the request says otherwise. "marks" is a small positive integer.
            """

        if let context, !context.isEmpty {
            request += """

                [Material]
                \(context)
                [End material]
                """
        }

        return request + "\n\nRequest: \(prompt)"
    }

    private static func quizGradingRequest(quiz: QuizTab, pending: [(index: Int, question: QuizQuestion)]) -> String {
        var lines: [String] = []
        for entry in pending {
            let question = entry.question
            let student = quiz.answers.indices.contains(entry.index - 1) ? quiz.answers[entry.index - 1] : ""
            lines.append(
                """
                Question \(entry.index) (worth \(question.marks) mark\(question.marks == 1 ? "" : "s")):
                Q: \(question.prompt)
                Model answer: \(question.answer)
                Student answer: \(student.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no answer)" : student)
                """)
        }

        return """
            Mark only the questions listed below. For each, decide whether the student's answer is correct, award an integer from 0 to the question's marks, and give one short sentence of feedback. Be tolerant of different wording. Respond with ONLY valid JSON — no prose, no markdown, no code fences — using exactly this shape:
            {"results": [{"index": 1, "correct": true, "awarded": 1, "feedback": "why"}]}
            Use each question's given number as its "index".

            \(lines.joined(separator: "\n\n"))
            """
    }

    private struct QuizFile: Codable {
        struct Item: Codable {
            let prompt: String
            let answer: String
            let marks: Int
            var type: String?
            var options: [String]?
        }
        let title: String
        let questions: [Item]
    }

    private func writeQuiz(title: String, questions: [QuizQuestion]) -> URL? {
        let base = (quizFolder as NSString).expandingTildeInPath
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let root = URL(fileURLWithPath: base, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fileURL = Self.uniqueFileURL(in: root, slug: Self.slug(title), ext: "json")
            let file = QuizFile(
                title: title,
                questions: questions.map { question in
                    QuizFile.Item(
                        prompt: question.prompt,
                        answer: question.answer,
                        marks: question.marks,
                        type: question.kind == .multipleChoice ? "mc" : "open",
                        options: question.options.isEmpty ? nil : question.options
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL)
            return fileURL
        } catch {
            log("Writing the quiz failed — \(error.localizedDescription)")
            return nil
        }
    }

    func openSavedQuiz(at url: URL) {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(QuizFile.self, from: data)
        else {
            log("Couldn’t read \(url.path)")
            return
        }
        let questions = file.questions.map { item in
            let options = item.options ?? []
            let kind: QuizQuestionKind = item.type == "mc" && options.count >= 2 ? .multipleChoice : .open
            return QuizQuestion(
                prompt: item.prompt, answer: item.answer, marks: item.marks, kind: kind,
                options: kind == .multipleChoice ? options : [])
        }
        library.openQuiz(QuizTab(title: file.title, questions: questions, fileURL: url))
        log("Opened quiz “\(file.title)”.")
    }

    struct SavedQuiz: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL
        let modified: Date
    }

    func refreshSavedQuizzes() {
        let root = URL(fileURLWithPath: (quizFolder as NSString).expandingTildeInPath, isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            savedQuizzes = []
            return
        }

        var list: [SavedQuiz] = []
        for entry in entries where entry.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: entry),
                let file = try? JSONDecoder().decode(QuizFile.self, from: data)
            else { continue }
            let modified =
                (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            list.append(SavedQuiz(id: entry.path, title: file.title, url: entry, modified: modified))
        }
        savedQuizzes = list.sorted { $0.modified > $1.modified }
    }

    func openSavedQuiz(_ quiz: SavedQuiz) {
        openSavedQuiz(at: quiz.url)
    }

    func promptRenameSavedQuiz(_ quiz: SavedQuiz) {
        let alert = NSAlert()
        alert.messageText = "Rename Quiz"
        alert.informativeText = "Enter a new name for “\(quiz.title)”."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = quiz.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            renameSavedQuiz(quiz, to: field.stringValue)
        }
    }

    func confirmDeleteSavedQuiz(_ quiz: SavedQuiz) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(quiz.title)”?"
        alert.informativeText = "The quiz file will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            deleteSavedQuiz(quiz)
        }
    }

    private func renameSavedQuiz(_ quiz: SavedQuiz, to newName: String) {
        refreshSavedQuizzes()
        let title = uniqueQuizTitle(newName, excluding: quiz.url)

        guard let data = try? Data(contentsOf: quiz.url),
            let file = try? JSONDecoder().decode(QuizFile.self, from: data)
        else {
            log("Couldn’t read \(quiz.url.path)")
            return
        }

        let renamed = QuizFile(title: title, questions: file.questions)
        let newURL = Self.uniqueFileURL(
            in: quiz.url.deletingLastPathComponent(),
            slug: Self.slug(title),
            ext: "json",
            excluding: quiz.url
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(renamed).write(to: newURL)
            if newURL != quiz.url {
                try FileManager.default.removeItem(at: quiz.url)
            }
            library.updateQuiz(filePath: quiz.url.path, title: title, newURL: newURL)
            refreshSavedQuizzes()
            log("Renamed quiz to “\(title)”.")
        } catch {
            log("Rename failed — \(error.localizedDescription)")
        }
    }

    private func deleteSavedQuiz(_ quiz: SavedQuiz) {
        do {
            try FileManager.default.trashItem(at: quiz.url, resultingItemURL: nil)
            library.closeQuizzes(filePath: quiz.url.path)
            refreshSavedQuizzes()
            log("Deleted quiz “\(quiz.title)”.")
        } catch {
            log("Delete failed — \(error.localizedDescription)")
        }
    }

    private func uniqueQuizTitle(_ desired: String, excluding url: URL?) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Quiz" : trimmed
        let existing = Set(savedQuizzes.filter { $0.url != url }.map { $0.title.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var suffix = 1
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Flashcards

    struct SavedDeck: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL
        let cardCount: Int
        let modified: Date
    }

    /// Rescans the flashcard folder for decks (subfolders containing `deck.json`).
    func refreshSavedDecks() {
        let root = URL(
            fileURLWithPath: (flashcardFolder as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let fileManager = FileManager.default

        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            savedDecks = []
            return
        }

        var decks: [SavedDeck] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }

            let deckFile = entry.appendingPathComponent("deck.json")
            guard let data = try? Data(contentsOf: deckFile),
                let decoded = try? JSONDecoder().decode(FlashcardDeckFile.self, from: data)
            else {
                continue
            }

            decks.append(
                SavedDeck(
                    id: entry.path,
                    title: decoded.title,
                    url: entry,
                    cardCount: decoded.cards.count,
                    modified: values?.contentModificationDate ?? .distantPast
                )
            )
        }

        savedDecks = decks.sorted { $0.modified > $1.modified }
    }

    func openSavedDeck(_ deck: SavedDeck) {
        guard let data = try? Data(contentsOf: deck.url.appendingPathComponent("deck.json")),
            let file = try? JSONDecoder().decode(FlashcardDeckFile.self, from: data)
        else {
            log("Couldn’t read \(deck.url.path)/deck.json")
            return
        }

        let cards = file.cards.map { Flashcard(front: $0.front, back: $0.back) }
        library.openFlashcard(FlashcardTab(title: file.title, cards: cards, deckURL: deck.url))
        log("Opened deck “\(file.title)” (\(cards.count) cards).")
    }

    func promptRenameDeck(_ deck: SavedDeck) {
        let alert = NSAlert()
        alert.messageText = "Rename Deck"
        alert.informativeText = "Enter a new name for “\(deck.title)”."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = deck.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            renameDeck(deck, to: field.stringValue)
        }
    }

    func confirmDeleteDeck(_ deck: SavedDeck) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(deck.title)”?"
        alert.informativeText = "The deck folder will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            deleteDeck(deck)
        }
    }

    private func renameDeck(_ deck: SavedDeck, to newName: String) {
        refreshSavedDecks()
        let title = uniqueDeckTitle(newName, excluding: deck.url)

        let deckFile = deck.url.appendingPathComponent("deck.json")
        guard let data = try? Data(contentsOf: deckFile),
            let existing = try? JSONDecoder().decode(FlashcardDeckFile.self, from: data)
        else {
            log("Couldn’t read \(deckFile.path)")
            return
        }

        let renamed = FlashcardDeckFile(title: title, cards: existing.cards)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(renamed).write(to: deckFile)

            if let markdown = Self.markdown(for: renamed).data(using: .utf8) {
                try markdown.write(to: deck.url.appendingPathComponent("cards.md"))
            }

            library.updateFlashcardTitle(deckPath: deck.url.path, title: title)
            refreshSavedDecks()
            log("Renamed deck to “\(title)”.")
        } catch {
            log("Rename failed — \(error.localizedDescription)")
        }
    }

    private func deleteDeck(_ deck: SavedDeck) {
        do {
            try FileManager.default.trashItem(at: deck.url, resultingItemURL: nil)
            library.closeFlashcards(deckPath: deck.url.path)
            refreshSavedDecks()
            log("Deleted deck “\(deck.title)”.")
        } catch {
            log("Delete failed — \(error.localizedDescription)")
        }
    }

    /// Keeps deck names distinct by appending "1", "2", … on a collision.
    private func uniqueDeckTitle(_ desired: String, excluding url: URL?) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Deck" : trimmed
        let existing = Set(
            savedDecks
                .filter { $0.url != url }
                .map { $0.title.lowercased() }
        )

        if !existing.contains(base.lowercased()) { return base }

        var suffix = 1
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    static func looksLikeFlashcards(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("flash card") || lower.contains("flash cards") || lower.contains("flip card") {
            return true
        }
        return
            lower
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "flashcard" || $0 == "flashcards" || $0 == "anki" }
    }

    func chooseFlashcardFolder() {
        guard let url = chooseFolder(message: "Choose where flashcard decks are saved", startingAt: flashcardFolder)
        else { return }
        flashcardFolder = url.path
        log("Flashcard folder set to \(url.path).")
    }

    func chooseSummaryFolder() {
        guard let url = chooseFolder(message: "Choose where summaries are saved", startingAt: summaryFolder) else {
            return
        }
        summaryFolder = url.path
        log("Summary folder set to \(url.path).")
    }

    func chooseQuizFolder() {
        guard let url = chooseFolder(message: "Choose where quizzes are saved", startingAt: quizFolder) else { return }
        quizFolder = url.path
        log("Quiz folder set to \(url.path).")
    }

    private func chooseFolder(message: String, startingAt path: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks opencode for flashcards, saves the deck to disk, and opens it in a tab.
    private func performFlashcards(prompt: String, context: String?, client: OpenCodeClient) async {
        log("Flashcard request detected — asking opencode for cards…")

        do {
            let session = try await ensureSession(client: client)
            let request = Self.flashcardGenerationRequest(prompt: prompt, context: context)
            let reply = try await client.sendMessage(sessionID: session, text: request, model: parsedModel)

            guard let deck = Self.parseFlashcards(reply) else {
                log("Couldn’t read flashcard JSON — showing the reply as a normal answer.")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachedContext: nil
                    )
                )
                return
            }

            refreshSavedDecks()
            let baseTitle = Self.deckTitle(document: library.activeTab?.title, model: deck.title, prompt: prompt)
            let title = uniqueDeckTitle(baseTitle, excluding: nil)
            let savedURL = writeDeck(title: title, cards: deck.cards)
            let tab = FlashcardTab(title: title, cards: deck.cards, deckURL: savedURL)
            library.openFlashcard(tab)
            addToActiveWorkbook(kind: .deck, title: title, url: savedURL)
            refreshSavedDecks()

            if let savedURL {
                log("Saved \(deck.cards.count) cards to \(savedURL.path).")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text:
                            "Created \(deck.cards.count) flashcards and saved them to “\(savedURL.path)”. They’re open in a new tab.",
                        attachedContext: nil
                    )
                )
            } else {
                log("Created flashcards but couldn’t save them to \(flashcardFolder).")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text:
                            "Created \(deck.cards.count) flashcards in a new tab, but saving them to “\(flashcardFolder)” failed. Check the folder in settings.",
                        attachedContext: nil
                    )
                )
            }
        } catch {
            log("Flashcard request failed — \(Self.describe(error))")
            messages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    private func writeDeck(title: String, cards: [Flashcard]) -> URL? {
        let base = (flashcardFolder as NSString).expandingTildeInPath
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let root = URL(fileURLWithPath: base, isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let deckURL = Self.uniqueURL(in: root, slug: Self.slug(title))
            try fileManager.createDirectory(at: deckURL, withIntermediateDirectories: true)

            let deckFile = FlashcardDeckFile(
                title: title,
                cards: cards.map { .init(front: $0.front, back: $0.back) }
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(deckFile).write(to: deckURL.appendingPathComponent("deck.json"))

            if let markdown = Self.markdown(for: deckFile).data(using: .utf8) {
                try markdown.write(to: deckURL.appendingPathComponent("cards.md"))
            }

            return deckURL
        } catch {
            log("Writing the deck failed — \(error.localizedDescription)")
            return nil
        }
    }

    private struct ParsedFlashcards {
        let title: String?
        let cards: [Flashcard]
    }

    private struct FlashcardPayload: Decodable {
        struct Item: Decodable {
            let front: String?
            let back: String?
        }
        let title: String?
        let cards: [Item]?
    }

    private struct FlashcardDeckFile: Codable {
        struct Card: Codable {
            let front: String
            let back: String
        }
        let title: String
        let cards: [Card]
    }

    private static func parseFlashcards(_ text: String) -> ParsedFlashcards? {
        guard let json = jsonObject(in: text), let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(FlashcardPayload.self, from: data)
        else {
            return nil
        }

        let cards = (payload.cards ?? []).compactMap { item -> Flashcard? in
            guard let front = item.front?.trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty,
                let back = item.back?.trimmingCharacters(in: .whitespacesAndNewlines), !back.isEmpty
            else {
                return nil
            }
            return Flashcard(front: front, back: back)
        }

        guard !cards.isEmpty else { return nil }
        return ParsedFlashcards(title: payload.title, cards: cards)
    }

    private static func uniqueURL(in root: URL, slug: String) -> URL {
        let fileManager = FileManager.default
        var candidate = root.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let replaced = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(replaced).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "deck" : String(collapsed.prefix(60))
    }

    private static func markdown(for deck: FlashcardDeckFile) -> String {
        var lines = ["# \(deck.title)", ""]
        for (index, card) in deck.cards.enumerated() {
            lines.append("**\(index + 1). \(card.front)**")
            lines.append("")
            lines.append(card.back)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func deckTitle(document: String?, model: String?, prompt: String) -> String {
        if let document = document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            return "\(document) Flashcards"
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            return model
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Flashcards" : trimmed
    }

    private static func flashcardGenerationRequest(prompt: String, context: String?) -> String {
        var request = """
            Create flashcards for revising for a final exam. Each card must test understanding that could actually be examined — concepts, reasoning, mechanisms, comparisons, cause and effect, and applications. Prefer "why", "how" and "what happens if" over isolated facts. Do not make cards for notation, symbol or parameter formats, bare definitions with no reasoning, or lecture-specific trivia — for example, "what format is a percept" is a waste of time and must be skipped. Write any mathematics as LaTeX (inline $...$, display $$...$$); since this is JSON, escape backslashes in LaTeX (write \\frac as \\\\frac). Respond with ONLY valid JSON — no prose, no markdown, no code fences — using exactly this shape:
            {"title": "Deck title", "cards": [{"front": "prompt or question", "back": "answer"}]}
            Make as many cards as the material genuinely supports: cover the distinct examinable ideas, but don't pad to a round number and don't add trivial, vague or repetitive filler. If the request asks for a specific number, follow that instead. Keep each side short and focused.
            """

        if let context, !context.isEmpty {
            request += "\n\n[Material]\n\(context)\n[End material]"
        }

        return request + "\n\nRequest: \(prompt)"
    }

    // MARK: - Annotations

    static func looksLikeAnnotate(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("margin note") || lower.contains("side note") { return true }
        return
            lower
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "annotate" || $0 == "annotation" || $0 == "annotations" }
    }

    private func performAnnotate() async {
        guard let tab = library.activeTab else {
            messages.append(
                ChatMessage(role: .assistant, text: "Open a PDF first, then I can annotate it.", attachedContext: nil)
            )
            return
        }

        library.showAnnotations = true
        await annotatePages(tab)

        let count = tab.pageNotes.count
        guard count > 0 else { return }
        messages.append(
            ChatMessage(
                role: .assistant,
                text: "Added notes beside \(count) page\(count == 1 ? "" : "s") of “\(tab.title)”.",
                attachedContext: nil
            )
        )
    }

    func annotatePages(_ tab: PDFDocumentTab) async {
        await generatePageNotes(tab, pages: Array(0..<tab.pageCount))
    }

    func annotateCurrentPage(_ tab: PDFDocumentTab) async {
        await generatePageNotes(tab, pages: [tab.pageIndex])
    }

    private func generatePageNotes(_ tab: PDFDocumentTab, pages: [Int]) async {
        guard !tab.isAnnotatingPages, !pages.isEmpty else { return }
        guard let client else {
            log("Can’t annotate — not connected to opencode.")
            return
        }
        guard let context = Self.pageContext(tab, pages: pages) else {
            log("No readable text to annotate for “\(tab.title)”.")
            return
        }

        tab.isAnnotatingPages = true
        log("Annotating \(pages.count) page\(pages.count == 1 ? "" : "s") of “\(tab.title)”…")
        defer { tab.isAnnotatingPages = false }

        do {
            let session = try await ensureSession(client: client)
            let request = Self.pageNotesRequest(document: tab.title, context: context)
            let reply = try await client.sendMessage(sessionID: session, text: request, model: parsedModel)
            let notes = Self.parsePageNotes(reply)
            guard !notes.isEmpty else {
                log("No per-page notes were found in the reply.")
                return
            }
            for (page, note) in notes {
                tab.pageNotes[page] = note
            }
            log("Notes ready for \(notes.count) page\(notes.count == 1 ? "" : "s").")
        } catch {
            log("Annotate failed — \(Self.describe(error))")
        }
    }

    private static func pageContext(_ tab: PDFDocumentTab, pages: [Int]) -> String? {
        var pieces: [String] = []
        for index in pages {
            guard let page = tab.document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            pieces.append("--- Page \(index + 1) ---\n\(text)")
        }
        guard !pieces.isEmpty else { return nil }
        return "Document: \(tab.title)\n\n" + pieces.joined(separator: "\n\n")
    }

    /// Parses "## Page N" sections into page-indexed notes.
    static func parsePageNotes(_ text: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var currentPage: Int?
        var buffer: [String] = []

        func flush() {
            guard let currentPage else { return }
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result[currentPage - 1] = body
            }
            buffer.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let page = pageHeadingNumber(String(line)) {
                flush()
                currentPage = page
            } else if currentPage != nil {
                buffer.append(String(line))
            }
        }
        flush()
        return result
    }

    private static func pageHeadingNumber(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let rest = trimmed.drop { $0 == "#" || $0 == " " }
        guard rest.lowercased().hasPrefix("page") else { return nil }
        let digits = rest.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func pageNotesRequest(document: String, context: String) -> String {
        """
        The reader has already read each page of this PDF, so your notes must ADD to it, never repeat it. Do not restate the slide's text. For every page below, supply only what isn't already spelled out: if a concept is introduced without a formal definition, provide a concise definition; explain the underlying why and intuition; give a concrete example or analogy; connect it to related ideas; note common pitfalls or misconceptions; and say why it matters or where it's used. Keep each page to a few tight bullets, and if a page genuinely has nothing to add (for example a title or agenda slide) write just "—".

        Write any mathematics as LaTeX (inline $...$, display $$...$$). Use Markdown with one section per page, each introduced by a heading in exactly the form "## Page N" where N is that page's number, followed by that page's notes and nothing else.

        \(context)
        """
    }

    // MARK: - Summaries

    struct SavedSummary: Identifiable, Hashable {
        let id: String
        let title: String
        let url: URL
        let modified: Date
    }

    static func looksLikeSummary(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("tl;dr") || lower.contains("summary")
            || lower.contains("summarize") || lower.contains("summarise")
        {
            return true
        }
        return
            lower
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "overview" || $0 == "recap" }
    }

    /// Rescans the summary folder for saved Markdown summaries.
    func refreshSavedSummaries() {
        let root = URL(
            fileURLWithPath: (summaryFolder as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let fileManager = FileManager.default

        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            savedSummaries = []
            return
        }

        var list: [SavedSummary] = []
        for entry in entries where entry.pathExtension.lowercased() == "md" {
            let modified =
                (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let title = Self.summaryFile(at: entry)?.title ?? entry.deletingPathExtension().lastPathComponent
            list.append(SavedSummary(id: entry.path, title: title, url: entry, modified: modified))
        }

        savedSummaries = list.sorted { $0.modified > $1.modified }
    }

    func openSavedSummary(_ summary: SavedSummary) {
        guard let parsed = Self.summaryFile(at: summary.url) else {
            log("Couldn’t read \(summary.url.path)")
            return
        }
        library.openSummary(SummaryTab(title: parsed.title, text: parsed.text, fileURL: summary.url))
        log("Opened summary “\(parsed.title)”.")
    }

    func promptRenameSummary(_ summary: SavedSummary) {
        let alert = NSAlert()
        alert.messageText = "Rename Summary"
        alert.informativeText = "Enter a new name for “\(summary.title)”."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = summary.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            renameSummary(summary, to: field.stringValue)
        }
    }

    func confirmDeleteSummary(_ summary: SavedSummary) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(summary.title)”?"
        alert.informativeText = "The summary file will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            deleteSummary(summary)
        }
    }

    private func performSummary(prompt: String, context: String?, client: OpenCodeClient) async {
        log("Summary request detected — asking opencode…")

        do {
            let session = try await ensureSession(client: client)
            let request = Self.summaryRequest(prompt: prompt, context: context)
            let reply = try await client.sendMessage(sessionID: session, text: request, model: parsedModel)
            let text = Self.cleanSummary(reply)

            guard !text.isEmpty else {
                log("Empty summary — showing the reply as a normal answer.")
                messages.append(
                    ChatMessage(
                        role: .assistant, text: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                        attachedContext: nil)
                )
                return
            }

            refreshSavedSummaries()
            let baseTitle = Self.summaryTitle(document: library.activeTab?.title)
            let title = uniqueSummaryTitle(baseTitle, excluding: nil)
            let savedURL = writeSummary(title: title, text: text)

            library.openSummary(SummaryTab(title: title, text: text, fileURL: savedURL))
            addToActiveWorkbook(kind: .summary, title: title, url: savedURL)
            refreshSavedSummaries()

            if let savedURL {
                log("Saved summary to \(savedURL.path).")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: "Created a summary and saved it to “\(savedURL.path)”. It’s open in a new tab.",
                        attachedContext: nil
                    )
                )
            } else {
                log("Created a summary but couldn’t save it to \(summaryFolder).")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text:
                            "Created a summary in a new tab, but saving it to “\(summaryFolder)” failed. Check the folder in settings.",
                        attachedContext: nil
                    )
                )
            }
        } catch {
            log("Summary request failed — \(Self.describe(error))")
            messages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    private func writeSummary(title: String, text: String) -> URL? {
        let base = (summaryFolder as NSString).expandingTildeInPath
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let root = URL(fileURLWithPath: base, isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let fileURL = Self.uniqueFileURL(in: root, slug: Self.slug(title))
            try Self.summaryFileContents(title: title, text: text).write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            log("Writing the summary failed — \(error.localizedDescription)")
            return nil
        }
    }

    private func renameSummary(_ summary: SavedSummary, to newName: String) {
        refreshSavedSummaries()
        let title = uniqueSummaryTitle(newName, excluding: summary.url)

        guard let parsed = Self.summaryFile(at: summary.url) else {
            log("Couldn’t read \(summary.url.path)")
            return
        }

        let root = summary.url.deletingLastPathComponent()
        let newURL = Self.uniqueFileURL(in: root, slug: Self.slug(title), excluding: summary.url)

        do {
            try Self.summaryFileContents(title: title, text: parsed.text).write(
                to: newURL, atomically: true, encoding: .utf8)
            if newURL != summary.url {
                try FileManager.default.removeItem(at: summary.url)
            }
            library.updateSummaryTitle(filePath: summary.url.path, title: title)
            if let open = library.summaries.first(where: { $0.fileURL?.path == summary.url.path }) {
                open.fileURL = newURL
            }
            refreshSavedSummaries()
            log("Renamed summary to “\(title)”.")
        } catch {
            log("Rename failed — \(error.localizedDescription)")
        }
    }

    private func deleteSummary(_ summary: SavedSummary) {
        do {
            try FileManager.default.trashItem(at: summary.url, resultingItemURL: nil)
            library.closeSummaries(filePath: summary.url.path)
            refreshSavedSummaries()
            log("Deleted summary “\(summary.title)”.")
        } catch {
            log("Delete failed — \(error.localizedDescription)")
        }
    }

    private static func summaryTitle(document: String?) -> String {
        if let document = document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            return "\(document) Summary"
        }
        return "Summary"
    }

    private func uniqueSummaryTitle(_ desired: String, excluding url: URL?) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Summary" : trimmed
        let existing = Set(
            savedSummaries
                .filter { $0.url != url }
                .map { $0.title.lowercased() }
        )

        if !existing.contains(base.lowercased()) { return base }

        var suffix = 1
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func summaryRequest(prompt: String, context: String?) -> String {
        var request = """
            Summarize the material below as a final-exam study aid, in clear, well-structured Markdown: a one-paragraph overview, then the key examinable concepts as bullets (definitions, mechanisms, comparisons, applications), then any important conclusions or takeaways. Write any mathematics as LaTeX (inline $...$, display $$...$$). Prioritise what is most likely to be assessed and leave out lecture-specific trivia, notation or parameter formats, and throwaway details. Be concise but cover everything important. Respond with Markdown only — no JSON, and don't wrap the whole answer in a code fence.
            """

        if let context, !context.isEmpty {
            request += "\n\n[Material]\n\(context)\n[End material]"
        }

        return request + "\n\nRequest: \(prompt)"
    }

    private static func cleanSummary(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func summaryFileContents(title: String, text: String) -> String {
        "# \(title)\n\n\(text)\n"
    }

    /// Reads a summary file, splitting the leading `# Title` heading off the body.
    private static func summaryFile(at url: URL) -> (title: String, text: String)? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var title = url.deletingPathExtension().lastPathComponent

        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }

    private static func uniqueFileURL(in root: URL, slug: String, ext: String = "md", excluding: URL? = nil) -> URL {
        let fileManager = FileManager.default
        var candidate = root.appendingPathComponent("\(slug).\(ext)")
        var suffix = 1
        while candidate != excluding, fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Workbook integration

    private func addToActiveWorkbook(kind: WorkbookItemKind, title: String, url: URL?) {
        guard let url, let workbookID = workbooks.activeWorkbookID,
            let workbook = workbooks.workbooks.first(where: { $0.id == workbookID })
        else { return }

        let folderName: String
        switch kind {
        case .pdf: folderName = "PDFs"
        case .summary: folderName = "Summaries"
        case .deck: folderName = "Flashcards"
        case .quiz: folderName = "Quizzes"
        case .note: folderName = "Notes"
        case .file: folderName = "Files"
        }

        let folderID: UUID?
        if let existing = workbook.folders.first(where: { $0.name.caseInsensitiveCompare(folderName) == .orderedSame })
        {
            folderID = existing.id
        } else {
            folderID = workbooks.addFolder(named: folderName, to: workbookID)
        }

        workbooks.add(workbooks.makeItem(kind: kind, title: title, url: url), to: workbookID, folderID: folderID)
    }

    // MARK: - Input history (up/down arrows)

    func recordHistory(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if history.last != trimmed {
            history.append(trimmed)
        }
        historyCursor = 0
        historyDraft = ""
    }

    func recallPrevious() {
        guard !history.isEmpty else { return }
        if historyCursor == 0 {
            historyDraft = input
        }
        historyCursor = min(history.count, historyCursor + 1)
        input = history[history.count - historyCursor]
    }

    func recallNext() {
        guard historyCursor > 0 else { return }
        historyCursor -= 1
        input = historyCursor == 0 ? historyDraft : history[history.count - historyCursor]
    }

    func resetHistoryCursor() {
        historyCursor = 0
        historyDraft = ""
    }

    private func ensureSession(client: OpenCodeClient) async throws -> String {
        if let sessionID { return sessionID }
        let created = try await client.createSession()
        sessionID = created
        return created
    }

    private var parsedModel: OpenCodeClient.ModelRef? {
        let value = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let provider = String(value[value.startIndex..<slash])
        let model = String(value[value.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return OpenCodeClient.ModelRef(providerID: provider, modelID: model)
    }

    // MARK: - Helpers

    private static func makeClient(for url: URL) -> OpenCodeClient {
        let credentials = credentials(for: url)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return OpenCodeClient(
            baseURL: components?.url ?? url,
            username: credentials.username,
            password: credentials.password
        )
    }

    /// Basic-auth credentials come from the URL's userinfo if present, otherwise
    /// from the environment (as `opencode serve` reads them).
    private static func credentials(for url: URL) -> (username: String?, password: String?) {
        if let user = url.user, let password = url.password {
            return (user, password)
        }
        let environment = ProcessInfo.processInfo.environment
        if let password = environment["OPENCODE_SERVER_PASSWORD"] {
            return (environment["OPENCODE_SERVER_USERNAME"] ?? "opencode", password)
        }
        return (nil, nil)
    }

    static func compose(question: String, context: String?) -> String {
        let latex = "Write any mathematics as LaTeX: inline math as $...$ and display equations as $$...$$."
        guard let context, !context.isEmpty else {
            return "\(latex)\n\n\(question)"
        }
        return """
            The user is reading a PDF in a macOS app. \(latex)

            [PDF page context]
            \(context)
            [End PDF page context]

            \(question)
            """
    }

    /// Builds the PDF text attached to a request for the given scope.
    static func context(for tab: PDFDocumentTab, scope: ContextScope) -> String? {
        switch scope {
        case .none:
            return nil
        case .currentPage:
            return currentPageContext(tab)
        case .wholeDocument:
            return wholeDocumentContext(tab)
        case .workbook:
            return workbookContext()
        }
    }

    private static var workbookCache: [UUID: (signature: String, text: String)] = [:]

    // MARK: - Workbook topic index (retrieval)

    fileprivate struct WorkbookChunk {
        let title: String
        let page: Int?
        let path: String
        let text: String
        let termCounts: [String: Int]
    }

    fileprivate struct WorkbookIndex {
        let signature: String
        let chunks: [WorkbookChunk]
        let documentFrequency: [String: Int]
    }

    private static var workbookIndexCache: [UUID: WorkbookIndex] = [:]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "is", "are", "was", "were", "be", "been",
        "it", "its", "this", "that", "these", "those", "for", "on", "with", "as", "at", "by", "from",
        "into", "than", "then", "so", "such", "but", "not", "no", "can", "could", "should", "would",
        "may", "might", "will", "shall", "do", "does", "did", "has", "have", "had", "how", "what",
        "when", "where", "which", "who", "whom", "why", "if", "about", "your", "you", "their", "they",
        "them", "he", "she", "his", "her", "we", "our", "us", "i", "explain", "describe", "tell", "me",
        "give", "list", "question", "answer", "please",
    ]

    private static func tokenize(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(raw)
            guard token.count >= 3, !stopWords.contains(token) else { continue }
            counts[token, default: 0] += 1
        }
        return counts
    }

    private static func workbookIndex(for workbook: Workbook, store: WorkbookStore) -> WorkbookIndex {
        var items: [WorkbookItem] = []
        func collect(_ folders: [WorkbookFolder]) {
            for folder in folders {
                collect(folder.folders)
                items.append(contentsOf: folder.items)
            }
        }
        collect(workbook.folders)
        items.append(contentsOf: workbook.items)

        var chunks: [WorkbookChunk] = []
        for item in items {
            switch item.kind {
            case .summary:
                guard let url = store.url(for: item),
                    let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                chunks.append(
                    WorkbookChunk(title: item.title, page: nil, path: item.path, text: text, termCounts: tokenize(text))
                )
            case .pdf:
                guard let url = store.url(for: item), let document = PDFDocument(url: url) else { continue }
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index),
                        let text = page.string,
                        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    chunks.append(
                        WorkbookChunk(
                            title: item.title, page: index + 1, path: item.path, text: text, termCounts: tokenize(text))
                    )
                }
            case .deck, .quiz, .note, .file:
                continue
            }
        }

        var df: [String: Int] = [:]
        for chunk in chunks {
            for key in chunk.termCounts.keys {
                df[key, default: 0] += 1
            }
        }

        let signature =
            workbook.id.uuidString + "|"
            + items.map { "\($0.kind.rawValue):\($0.path)" }.joined(separator: "|")
        return WorkbookIndex(signature: signature, chunks: chunks, documentFrequency: df)
    }

    /// Context assembled from the active workbook. When `focusPath` is set (the
    /// open PDF) its text comes first, so the model focuses on it while still
    /// having the whole workbook available. Distilled Markdown summaries are
    /// included next (cheap), then the remaining PDFs, up to a total budget.
    /// Cached until the workbook's contents change.
    static func workbookContext(query: String? = nil, focusPath: String? = nil) -> String? {
        let store = WorkbookStore.shared

        // Prefer the explicitly-active workbook, else the one that owns the
        // document currently open — so this is always the *whole* workbook.
        var resolved: Workbook?
        if let id = store.activeWorkbookID {
            resolved = store.workbooks.first(where: { $0.id == id })
        }
        if resolved == nil, let path = LibraryStore.shared.selectedTab?.url.path {
            resolved = store.workbooks.first(where: { $0.containsPath(path) })
        }
        guard let workbook = resolved else { return nil }
        let id = workbook.id

        var items: [WorkbookItem] = []
        func collect(_ folders: [WorkbookFolder]) {
            for folder in folders {
                collect(folder.folders)
                items.append(contentsOf: folder.items)
            }
        }
        collect(workbook.folders)
        items.append(contentsOf: workbook.items)
        guard !items.isEmpty else { return nil }

        let signature =
            (focusPath ?? "") + "|" + (query ?? "")
            + "|" + items.map { "\($0.kind.rawValue):\($0.path)" }.joined(separator: "|")
        if let cached = workbookCache[id], cached.signature == signature {
            return cached.text
        }

        let summaries = items.filter { $0.kind == .summary }
        let pdfs = items.filter { $0.kind == .pdf }

        var orderedPDFs: [WorkbookItem] = []
        if let focusPath, let focus = pdfs.first(where: { $0.path == focusPath }) {
            orderedPDFs.append(focus)
        }
        orderedPDFs.append(contentsOf: pdfs.filter { $0.path != focusPath })

        let budget = 80_000
        let perDocumentCap = max(3_000, budget / max(1, orderedPDFs.count))
        var pieces: [String] = []
        var used = 0

        func append(_ header: String, _ body: String) -> Bool {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            let piece = "## \(header)\n\(trimmed)"
            if used + piece.count > budget {
                let remaining = budget - used
                if remaining > 200 {
                    pieces.append(String(piece.prefix(remaining)))
                    used = budget
                }
                return false
            }
            pieces.append(piece)
            used += piece.count
            return true
        }

        // Distilled Markdown summaries first — small, and they cover the workbook.
        for item in summaries {
            if used >= budget { break }
            guard let url = store.url(for: item),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if !append(item.title, text) { break }
        }

        // Retrieval: pull just the sections relevant to the question from the
        // topic index, so specific topics are answered from the right pages
        // instead of a fixed slice of the workbook.
        let queryTokens = Set(tokenize(query ?? "").keys)
        if !queryTokens.isEmpty {
            let index = workbookIndex(for: workbook, store: store)
            let total = max(1, index.chunks.count)

            var scored: [(chunk: WorkbookChunk, score: Double)] = []
            for chunk in index.chunks where chunk.page != nil {
                var score = 0.0
                for token in queryTokens {
                    guard let tf = chunk.termCounts[token] else { continue }
                    let df = index.documentFrequency[token] ?? 1
                    score += Double(tf) * (Darwin.log(Double(total) / Double(df)) + 1)
                }
                guard score > 0 else { continue }
                if chunk.path == focusPath { score *= 1.5 }
                scored.append((chunk, score))
            }
            scored.sort { $0.score > $1.score }

            if !scored.isEmpty {
                for entry in scored {
                    if used >= budget { break }
                    let pageLabel = entry.chunk.page.map { " — page \($0)" } ?? ""
                    if !append(entry.chunk.title + pageLabel, entry.chunk.text) { break }
                }
                guard !pieces.isEmpty else { return nil }
                let header = "Workbook: \(workbook.name) — relevant sections\n\n"
                let text = header + pieces.joined(separator: "\n\n")
                workbookCache[id] = (signature, text)
                return text
            }
        }

        // No query (or no matches): represent the whole workbook, each PDF
        // capped so one large document can't consume the entire budget.
        for item in orderedPDFs {
            if used >= budget { break }
            guard let url = store.url(for: item), let document = PDFDocument(url: url) else { continue }
            var text = ""
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let pageText = page.string, !pageText.isEmpty else {
                    continue
                }
                text += "\n--- Page \(index + 1) ---\n\(pageText)"
                if text.count >= perDocumentCap { break }
            }
            let header = item.path == focusPath ? "\(item.title) (open document)" : item.title
            if !append(header, text) { break }
        }

        guard !pieces.isEmpty else { return nil }
        let header = "Workbook: \(workbook.name) — \(items.count) item\(items.count == 1 ? "" : "s")\n\n"
        let text = header + pieces.joined(separator: "\n\n")
        workbookCache[id] = (signature, text)
        return text
    }

    private static func currentPageContext(_ tab: PDFDocumentTab) -> String? {
        guard let page = tab.document.page(at: tab.pageIndex) else { return nil }
        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "Document: \(tab.title) — page \(tab.pageIndex + 1) of \(tab.pageCount)\n\n\(text)"
    }

    private static func wholeDocumentContext(_ tab: PDFDocumentTab) -> String? {
        let budget = 40_000
        var pieces: [String] = []
        var used = 0
        var truncated = false

        for index in 0..<tab.pageCount {
            guard let page = tab.document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let chunk = "--- Page \(index + 1) ---\n\(text)"
            if used + chunk.count > budget {
                let remaining = budget - used
                if remaining > 0 {
                    pieces.append(String(chunk.prefix(remaining)))
                }
                truncated = true
                break
            }
            used += chunk.count
            pieces.append(chunk)
        }

        guard !pieces.isEmpty else { return nil }
        let pages = "\(tab.pageCount) page\(tab.pageCount == 1 ? "" : "s")"
        var header = "Document: \(tab.title) — \(pages)"
        if truncated {
            header += " (text truncated to fit the context limit)"
        }
        return header + "\n\n" + pieces.joined(separator: "\n\n")
    }

    static func normalizedURL(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "http://" + value
        }
        guard let url = URL(string: value), url.host != nil else { return nil }
        return url
    }

    private static func port(from address: String) -> Int {
        normalizedURL(from: address)?.port ?? 4096
    }

    private static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func locateOpenCodeBinary() -> URL? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.bun/bin/opencode",
            "\(home)/.local/bin/opencode",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
