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

    private static let addressKey = "openCodeServerAddress"
    private static let modelKey = "openCodeModelOverride"

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
