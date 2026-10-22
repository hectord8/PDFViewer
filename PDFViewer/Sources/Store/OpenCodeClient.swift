import Foundation

/// Thin HTTP client for a running `opencode serve` instance.
final class OpenCodeClient {
    struct ClientError: LocalizedError {
        enum Kind: Equatable {
            case unreachable
            case http(Int)
            case server(String)
            case invalidResponse
        }

        let kind: Kind
        let message: String

        init(_ kind: Kind, _ message: String) {
            self.kind = kind
            self.message = message
        }

        var errorDescription: String? { message }
    }

    struct Health: Decodable {
        let healthy: Bool
        let version: String?
    }

    struct ModelRef {
        let providerID: String
        let modelID: String
    }

    private struct SessionInfo: Decodable {
        let id: String
    }

    private struct EncodedModel: Encodable {
        let providerID: String
        let modelID: String
    }

    private struct TextPart: Encodable {
        let type = "text"
        let text: String
    }

    private struct MessageBody: Encodable {
        let model: EncodedModel?
        let parts: [TextPart]
    }

    private struct ErrorPayload: Decodable {
        let message: String?
    }

    private struct ErrorEnvelope: Decodable {
        let name: String?
        let data: ErrorPayload?
    }

    private struct Part: Decodable {
        let type: String?
        let text: String?
    }

    private struct MessageInfo: Decodable {
        let id: String?
        let role: String?
        let error: ErrorEnvelope?
    }

    private struct MessageResponse: Decodable {
        let info: MessageInfo?
        let parts: [Part]?
    }

    private struct MessageListItem: Decodable {
        let info: MessageInfo?
        let parts: [Part]?
    }

    let baseURL: URL

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let authorization: String?

    init(baseURL: URL, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            self.authorization = "Basic \(token)"
        } else {
            self.authorization = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func health() async throws -> Health {
        try await get("/global/health")
    }

    func createSession() async throws -> String {
        let data = try encoder.encode(["title": "PDF Viewer chat"])
        let info: SessionInfo = try await send("POST", "/session", body: data, timeout: 30)
        return info.id
    }

    func abort(sessionID: String) async {
        _ = try? await sendRaw("POST", "/session/\(sessionID)/abort", body: nil, timeout: 10)
    }

    func sendMessage(sessionID: String, text: String, model: ModelRef? = nil) async throws -> String {
        let encodedModel = model.map { EncodedModel(providerID: $0.providerID, modelID: $0.modelID) }
        let body = try encoder.encode(MessageBody(model: encodedModel, parts: [TextPart(text: text)]))
        let response: MessageResponse = try await send(
            "POST",
            "/session/\(sessionID)/message",
            body: body,
            timeout: 900
        )

        if let message = response.info?.error?.data?.message {
            throw ClientError(.server(message), message)
        }

        let joined = (response.parts ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return joined
        }
        return try await lastAssistantText(sessionID: sessionID)
    }

    private func lastAssistantText(sessionID: String) async throws -> String {
        let items: [MessageListItem] = try await get("/session/\(sessionID)/message")
        guard let last = items.last(where: { $0.info?.role == "assistant" }) else { return "" }
        if let message = last.info?.error?.data?.message {
            throw ClientError(.server(message), message)
        }
        return (last.parts ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await sendRaw("GET", path, body: nil, timeout: 30)
        return try decode(data)
    }

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> T {
        let data = try await sendRaw(method, path, body: body, timeout: timeout)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError(.invalidResponse, "Unexpected response from the opencode server.")
        }
    }

    @discardableResult
    private func sendRaw(
        _ method: String,
        _ path: String,
        body: Data?,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ClientError(.invalidResponse, "Invalid server address.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError(.invalidResponse, "No response from the opencode server.")
            }
            guard (200..<300).contains(http.statusCode) else {
                if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
                    let message = envelope.data?.message
                {
                    throw ClientError(.http(http.statusCode), message)
                }
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ClientError(
                    .http(http.statusCode),
                    text?.isEmpty == false
                        ? text!
                        : "opencode returned HTTP \(http.statusCode).")
            }
            return data
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError(.unreachable, "Couldn’t reach the opencode server at \(baseURL.absoluteString).")
        }
    }
}
