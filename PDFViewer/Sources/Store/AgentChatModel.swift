import AppKit
import Foundation

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
        case currentPage
        case none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .wholeDocument: return "Whole document"
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
    @Published var input: String = ""
    @Published var contextScope: ContextScope = .wholeDocument
    @Published var status: Status = .disconnected
    @Published var isSending = false
    @Published var logs: [LogEntry] = []
    @Published var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.addressKey) }
    }
    @Published var modelOverride: String {
        didSet { UserDefaults.standard.set(modelOverride, forKey: Self.modelKey) }
    }
    @Published var flashcardFolder: String {
        didSet {
            UserDefaults.standard.set(flashcardFolder, forKey: Self.flashcardFolderKey)
            refreshSavedDecks()
        }
    }
    @Published private(set) var savedDecks: [SavedDeck] = []

    private static let addressKey = "openCodeServerAddress"
    private static let modelKey = "openCodeModelOverride"
    private static let flashcardFolderKey = "flashcardFolder"

    private let library = LibraryStore.shared

    private var sessionID: String?
    private var client: OpenCodeClient?
    private var serverProcess: Process?
    private var serverLogPipe: Pipe?

    private var history: [String] = []
    private var historyCursor = 0
    private var historyDraft = ""

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let defaultModel = "opencode/space-bunny-free"

    private init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.addressKey) ?? "http://127.0.0.1:4096"
        modelOverride = UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.defaultModel
        flashcardFolder = UserDefaults.standard.string(forKey: Self.flashcardFolderKey) ?? Self.defaultFlashcardFolder
    }

    private static var defaultFlashcardFolder: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/PDFViewer/Flashcards")
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
        } catch {
            let unreachable = (error as? OpenCodeClient.ClientError)?.kind == .unreachable
            if unreachable, Self.isLocal(url), serverProcess?.isRunning != true {
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
        } catch {
            log("Test failed — \(Self.describe(error))")
        }
    }

    /// Starts `opencode serve` using a locally installed binary, then connects.
    func startServer() async {
        if serverProcess?.isRunning == true {
            log("Server already running; connecting…")
            await connect()
            return
        }

        guard let binary = Self.locateOpenCodeBinary() else {
            status = .failed("Couldn’t find the opencode executable. Run `opencode serve` in a terminal, then Connect.")
            log("Couldn’t find the opencode executable.")
            return
        }

        let port = Self.port(from: serverAddress)
        status = .connecting
        log("Starting \(binary.path) serve --port \(port)…")

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "serve",
            "--port", String(port),
            "--hostname", "127.0.0.1",
            "--print-logs"
        ]

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

        let attached = context
        messages.append(ChatMessage(role: .user, text: prompt, attachedContext: attached))

        if Self.looksLikeFlashcards(prompt) {
            await performFlashcards(prompt: prompt, context: attached, client: client)
            return
        }

        if Self.looksLikeQuiz(prompt) {
            await performQuiz(prompt: prompt, context: attached, client: client)
            return
        }

        let modelName = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        log("Sending request\(modelName.isEmpty ? "" : " (model \(modelName))")…")

        do {
            let session = try await ensureSession(client: client)
            let payload = Self.compose(question: prompt, context: attached)
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
        messages.removeAll()
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
            let tab = QuizTab(title: title, questions: quiz.questions)
            library.openQuiz(tab)

            log("Created quiz “\(title)” with \(tab.questions.count) questions.")
            messages.append(
                ChatMessage(
                    role: .assistant,
                    text: "Created the quiz “\(title)” with \(tab.questions.count) question\(tab.questions.count == 1 ? "" : "s"). Answer in the new tab, then press “Mark quiz”.",
                    attachedContext: nil
                )
            )
        } catch {
            log("Quiz request failed — \(Self.describe(error))")
            messages.append(ChatMessage(role: .error, text: Self.describe(error), attachedContext: nil))
        }
    }

    /// Sends the reader's answers to opencode and records the per-question marks.
    func mark(_ quiz: QuizTab) async {
        guard !quiz.isMarking, !quiz.marked else { return }
        guard let client else {
            log("Can’t mark — not connected to opencode.")
            return
        }

        quiz.isMarking = true
        defer { quiz.isMarking = false }
        log("Marking quiz “\(quiz.title)”…")

        do {
            let session = try await ensureSession(client: client)
            let request = Self.quizGradingRequest(quiz: quiz)
            let reply = try await client.sendMessage(sessionID: session, text: request, model: parsedModel)

            guard let results = Self.parseGrading(reply, questions: quiz.questions) else {
                log("Couldn’t read the marking result — try again.")
                return
            }

            quiz.results = results
            quiz.marked = true
            log("Marked “\(quiz.title)” — \(results.filter(\.correct).count)/\(quiz.questions.count) correct.")
        } catch {
            log("Marking failed — \(Self.describe(error))")
        }
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
              let payload = try? JSONDecoder().decode(QuizPayload.self, from: data) else {
            return nil
        }

        let questions = (payload.questions ?? []).compactMap { item -> QuizQuestion? in
            guard let prompt = item.question?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else { return nil }
            return QuizQuestion(
                prompt: prompt,
                answer: item.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                marks: max(1, item.marks ?? 1)
            )
        }

        guard !questions.isEmpty else { return nil }
        return ParsedQuiz(title: payload.title, questions: questions)
    }

    private static func parseGrading(_ text: String, questions: [QuizQuestion]) -> [QuizResult]? {
        guard let json = jsonObject(in: text), let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GradePayload.self, from: data),
              let items = payload.results, !items.isEmpty else {
            return nil
        }

        var results: [QuizResult] = []
        for (position, item) in items.enumerated() {
            let index = item.index ?? (position + 1)
            guard index >= 1, index <= questions.count else { continue }
            let marks = questions[index - 1].marks
            let correct = item.correct ?? false
            let awarded = min(max(item.awarded ?? (correct ? marks : 0), 0), marks)
            results.append(
                QuizResult(
                    index: index,
                    correct: correct,
                    awarded: awarded,
                    feedback: item.feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            )
        }

        return results.isEmpty ? nil : results
    }

    private static func jsonObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
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
        Create a short quiz that tests understanding of the material. Respond with ONLY valid JSON — no prose, no markdown, no code fences — using exactly this shape:
        {"title": "Quiz title", "questions": [{"question": "The question text", "answer": "A concise model answer used for marking", "marks": 1}]}
        Write 5 questions unless the request says otherwise. "marks" is a small positive integer.
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

    private static func quizGradingRequest(quiz: QuizTab) -> String {
        var lines: [String] = []
        for (index, question) in quiz.questions.enumerated() {
            let student = quiz.answers.indices.contains(index) ? quiz.answers[index] : ""
            lines.append("""
            Question \(index + 1) (worth \(question.marks) mark\(question.marks == 1 ? "" : "s")):
            Q: \(question.prompt)
            Model answer: \(question.answer)
            Student answer: \(student.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no answer)" : student)
            """)
        }

        return """
        Mark this quiz. For each question decide whether the student's answer is correct, award an integer from 0 to the question's marks, and give one short sentence of feedback. Be tolerant of different wording; an empty answer is incorrect. Respond with ONLY valid JSON — no prose, no markdown, no code fences — using exactly this shape:
        {"results": [{"index": 1, "correct": true, "awarded": 1, "feedback": "why"}]}

        \(lines.joined(separator: "\n\n"))
        """
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

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            savedDecks = []
            return
        }

        var decks: [SavedDeck] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }

            let deckFile = entry.appendingPathComponent("deck.json")
            guard let data = try? Data(contentsOf: deckFile),
                  let decoded = try? JSONDecoder().decode(FlashcardDeckFile.self, from: data) else {
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
              let file = try? JSONDecoder().decode(FlashcardDeckFile.self, from: data) else {
            log("Couldn’t read \(deck.url.path)/deck.json")
            return
        }

        let cards = file.cards.map { Flashcard(front: $0.front, back: $0.back) }
        library.openFlashcard(FlashcardTab(title: file.title, cards: cards, deckURL: deck.url))
        log("Opened deck “\(file.title)” (\(cards.count) cards).")
    }

    static func looksLikeFlashcards(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("flash card") || lower.contains("flash cards") || lower.contains("flip card") {
            return true
        }
        return lower
            .split(whereSeparator: { !$0.isLetter })
            .contains { $0 == "flashcard" || $0 == "flashcards" || $0 == "anki" }
    }

    func chooseFlashcardFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where flashcard decks are saved"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (flashcardFolder as NSString).expandingTildeInPath)

        if panel.runModal() == .OK, let url = panel.url {
            flashcardFolder = url.path
            log("Flashcard folder set to \(url.path).")
        }
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

            let title = Self.deckTitle(document: library.activeTab?.title, model: deck.title, prompt: prompt)
            let savedURL = writeDeck(title: title, cards: deck.cards)
            let tab = FlashcardTab(title: title, cards: deck.cards, deckURL: savedURL)
            library.openFlashcard(tab)
            refreshSavedDecks()

            if let savedURL {
                log("Saved \(deck.cards.count) cards to \(savedURL.path).")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: "Created \(deck.cards.count) flashcards and saved them to “\(savedURL.path)”. They’re open in a new tab.",
                        attachedContext: nil
                    )
                )
            } else {
                log("Created flashcards but couldn’t save them to \(flashcardFolder).")
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: "Created \(deck.cards.count) flashcards in a new tab, but saving them to “\(flashcardFolder)” failed. Check the folder in settings.",
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
              let payload = try? JSONDecoder().decode(FlashcardPayload.self, from: data) else {
            return nil
        }

        let cards = (payload.cards ?? []).compactMap { item -> Flashcard? in
            guard let front = item.front?.trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty,
                  let back = item.back?.trimmingCharacters(in: .whitespacesAndNewlines), !back.isEmpty else {
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
        Create a set of flashcards. Respond with ONLY valid JSON — no prose, no markdown, no code fences — using exactly this shape:
        {"title": "Deck title", "cards": [{"front": "prompt or question", "back": "answer"}]}
        Write 10 cards unless the request says otherwise. Keep each side short and focused.
        """

        if let context, !context.isEmpty {
            request += "\n\n[Material]\n\(context)\n[End material]"
        }

        return request + "\n\nRequest: \(prompt)"
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
        guard let context, !context.isEmpty else { return question }
        return """
        The user is reading a PDF in a macOS app. Use the page text below as context.

        [PDF page context]
        \(context)
        [End PDF page context]

        \(question)
        """
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
            "\(home)/.local/bin/opencode"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
