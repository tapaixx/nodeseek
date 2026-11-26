import Foundation
import Security

struct ChatAssistantAPIConfiguration: Codable, Equatable {
    let endpoint: URL
    let model: String
    let key: String

    init?(address: String, model: String, key: String) {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil else { return nil }
        let path = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = path.isEmpty ? "/v1/chat/completions"
            : "/" + path + (path == "chat/completions" || path.hasSuffix("/chat/completions") ? "" : "/chat/completions")
        guard let endpoint = parts.url else { return nil }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        self.endpoint = endpoint
        self.model = model
        self.key = key
    }
}

enum ChatAssistantAPIStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.mistj.nodeseek",
         kSecAttrAccount as String: "chat-assistant-custom-api"]
    }

    static func load() -> ChatAssistantAPIConfiguration? {
        var result: CFTypeRef?
        let lookup = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, value in value }
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode(ChatAssistantAPIConfiguration.self, from: data) else { return nil }
        return ChatAssistantAPIConfiguration(address: decoded.endpoint.absoluteString, model: decoded.model, key: decoded.key)
    }

    static func save(_ configuration: ChatAssistantAPIConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

struct ChatAssistantAPIMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct ChatAssistantAPI {
    private struct Request: Encodable {
        let model: String
        let messages: [ChatAssistantAPIMessage]
        let stream: Bool
    }
    private struct Response: Decodable {
        struct Choice: Decodable { let message: ChatAssistantAPIMessage }
        let choices: [Choice]
    }
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
            let message: ChatAssistantAPIMessage?
        }
        let choices: [Choice]
    }
    enum Failure: Error { case rejected, empty }

    func generate(configuration: ChatAssistantAPIConfiguration, instructions: String, conversation: String,
                  transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        let messages = [
            ChatAssistantAPIMessage(role: "system", content: instructions),
            ChatAssistantAPIMessage(role: "user", content: conversation)
        ]
        return try await chat(configuration: configuration, messages: messages, transport: transport)
    }

    func chat(configuration: ChatAssistantAPIConfiguration,
              messages: [ChatAssistantAPIMessage],
              transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        let request = try makeRequest(configuration: configuration, messages: messages, stream: false)
        let data: Data
        let response: URLResponse
        if let transport {
            (data, response) = try await transport(request)
        } else {
            let session = makeSession()
            defer { session.finishTasksAndInvalidate() }
            (data, response) = try await session.data(for: request)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw Failure.rejected
        }
        guard let text = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw Failure.empty
        }
        return text
    }

    /// 流式多轮对话；若服务端未返回 SSE 而直接返回普通 JSON，则自动降级解析。
    func streamChat(configuration: ChatAssistantAPIConfiguration,
                    messages: [ChatAssistantAPIMessage],
                    onDelta: @MainActor @escaping (String) -> Void) async throws -> String {
        let request = try makeRequest(configuration: configuration, messages: messages, stream: true)
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.rejected
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if !contentType.contains("text/event-stream") {
            var rawData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                rawData.append(byte)
            }
            if let decoded = try? JSONDecoder().decode(Response.self, from: rawData),
               let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                await onDelta(content)
                return content
            }
            // 部分代理未标明 text/event-stream 但实际按 SSE 行返回，继续尝试按行解析。
            if let fallback = Self.parseSSEPayload(String(decoding: rawData, as: UTF8.self)), !fallback.isEmpty {
                await onDelta(fallback)
                return fallback
            }
            throw Failure.empty
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let delta = Self.extractSSEDelta(from: line) else { continue }
            if delta == "[DONE]" { break }
            accumulated += delta
            await onDelta(accumulated)
        }

        let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { throw Failure.empty }
        return finalText
    }

    static func extractSSEDelta(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return nil }
        if payload == "[DONE]" { return "[DONE]" }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
              let choice = chunk.choices.first else {
            return nil
        }
        return choice.delta?.content ?? choice.message?.content
    }

    static func parseSSEPayload(_ text: String) -> String? {
        var result = ""
        for line in text.components(separatedBy: .newlines) {
            guard let delta = extractSSEDelta(from: line) else { continue }
            if delta == "[DONE]" { break }
            result += delta
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeRequest(configuration: ChatAssistantAPIConfiguration,
                             messages: [ChatAssistantAPIMessage],
                             stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        if !configuration.key.isEmpty {
            request.setValue("Bearer \(configuration.key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: messages, stream: stream))
        return request
    }

    private func makeSession() -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        return URLSession(configuration: settings, delegate: ChatAssistantRedirectPolicy(), delegateQueue: nil)
    }
}

private final class ChatAssistantRedirectPolicy: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
