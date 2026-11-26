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

struct ChatAssistantAPI {
    private struct Message: Codable { let role: String; let content: String }
    private struct Request: Encodable { let model: String; let messages: [Message]; let stream = false }
    private struct Response: Decodable {
        struct Choice: Decodable { let message: Message }
        let choices: [Choice]
    }
    enum Failure: Error { case rejected, empty }

    func generate(configuration: ChatAssistantAPIConfiguration, instructions: String, conversation: String,
                  transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.key.isEmpty { request.setValue("Bearer \(configuration.key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: [
            Message(role: "system", content: instructions), Message(role: "user", content: conversation)
        ]))
        let data: Data
        let response: URLResponse
        if let transport { (data, response) = try await transport(request) }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpShouldSetCookies = false
            settings.httpCookieStorage = nil
            settings.urlCache = nil
            let session = URLSession(configuration: settings, delegate: ChatAssistantRedirectPolicy(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            (data, response) = try await session.data(for: request)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { throw Failure.rejected }
        guard let text = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw Failure.empty }
        return text
    }
}

private final class ChatAssistantRedirectPolicy: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
