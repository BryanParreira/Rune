import Foundation

/// Minimal Ollama HTTP client: model list and streaming chat.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public struct ChatMessage: Codable, Equatable, Sendable {
        public var role: String
        public var content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// One streamed piece of a reply.
    public enum ChatEvent: Equatable, Sendable {
        case thinking(String)
        case content(String)
        case done
    }

    public enum ClientError: Error, LocalizedError, Equatable {
        case http(Int, String)
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Ollama returned HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
            case .server(let message): return message
            }
        }
    }

    // MARK: Models

    public func listModels() async throws -> [OllamaModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return try Self.parseTags(data)
    }

    public static func parseTags(_ data: Data) throws -> [OllamaModel] {
        struct Tags: Decodable {
            struct Model: Decodable {
                struct Details: Decodable { var parameter_size: String? }
                var name: String
                var size: Int64?
                var details: Details?
                var capabilities: [String]?
            }
            var models: [Model]
        }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        return tags.models.map {
            OllamaModel(name: $0.name, sizeBytes: $0.size, parameterSize: $0.details?.parameter_size, capabilities: $0.capabilities ?? [])
        }
    }

    // MARK: Chat

    /// Streams a chat reply. Cancel the consuming task to stop generation (the HTTP request is
    /// cancelled, which makes Ollama stop too).
    public func chat(model: String, messages: [ChatMessage], disableThinking: Bool) -> AsyncThrowingStream<ChatEvent, Error> {
        let body = Self.chatBody(model: model, messages: messages, disableThinking: disableThinking)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300
        let session = session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 400 { break } }
                        throw ClientError.http(http.statusCode, Self.errorMessage(in: text) ?? text)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in try Self.parseChatLine(line) {
                            continuation.yield(event)
                            if event == .done { continuation.finish(); return }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func chatBody(model: String, messages: [ChatMessage], disableThinking: Bool) -> Data {
        var object: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "options": ["temperature": 0.2],
            // Keep the model in memory between questions so follow-ups start immediately.
            "keep_alive": "30m",
        ]
        if disableThinking { object["think"] = false }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Parses one NDJSON line from /api/chat.
    static func parseChatLine(_ line: String) throws -> [ChatEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let error = object["error"] as? String { throw ClientError.server(error) }
        var events: [ChatEvent] = []
        if let message = object["message"] as? [String: Any] {
            if let thinking = message["thinking"] as? String, !thinking.isEmpty { events.append(.thinking(thinking)) }
            if let content = message["content"] as? String, !content.isEmpty { events.append(.content(content)) }
        }
        if object["done"] as? Bool == true { events.append(.done) }
        return events
    }

    static func errorMessage(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }
}
