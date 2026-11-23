import Foundation

// 面向多个业务模块的 JSON 值；页面显式选择业务字段，不把接口字段或原始 JSON 暴露给用户。
enum TradeValue: Codable, Equatable {
    case object([String: TradeValue]), array([TradeValue]), string(String), number(Decimal), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([String: TradeValue].self) { self = .object(v) }
        else { self = .array(try c.decode([TradeValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> TradeValue {
        guard case .object(let o) = self else { return .null }
        if let value = o[key] { return value }
        // 该值也可嵌套在使用 convertFromSnakeCase 的强类型响应中。
        let parts = key.split(separator: "_")
        let converted = (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return o[converted] ?? .null
    }
    var text: String? {
        switch self { case .string(let s): s; case .number(let n): NSDecimalNumber(decimal: n).stringValue; default: nil }
    }
    var list: [TradeValue] { if case .array(let a) = self { return a }; return [] }
    var flag: Bool { self == .bool(true) }
    var integer: Int? { text.flatMap(Int.init) }
    var id: Int64? { text.flatMap(Int64.init) }
    var isNull: Bool { self == .null }
    var object: [String: TradeValue] { if case .object(let o) = self { return o }; return [:] }
    static func id(_ value: Int64) -> Self { .number(Decimal(value)) }
}

@MainActor
protocol TradeWorkspaceServing: AnyObject {
    func read(_ path: String, query: [String: String]) async throws -> TradeValue
    func write(_ path: String, method: String, fields: [String: TradeValue]) async throws -> TradeValue
    func uploadImage(_ data: Data, conversationID: Int64) async throws -> TradeValue
    func image(_ path: String) async throws -> Data
}

extension TradeAPIClient: TradeWorkspaceServing {
    static func decodeWorkspaceMessage(_ value: TradeValue) throws -> TradeMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TradeMessage.self, from: JSONEncoder().encode(value))
    }
    func read(_ path: String, query: [String: String] = [:]) async throws -> TradeValue {
        guard Self.allowedWorkspacePath(path) else { throw Failure.invalidResponse }
        var parts = URLComponents()
        parts.path = path
        parts.queryItems = query.sorted { $0.key < $1.key }.filter { !$0.value.isEmpty }.map { .init(name: $0.key, value: $0.value) }
        let target = parts.percentEncodedPath + (parts.percentEncodedQuery.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? "")
        return try await request(TradeValue.self, path: target)
    }
    func write(_ path: String, method: String = "POST", fields: [String: TradeValue] = [:]) async throws -> TradeValue {
        guard Self.allowedWorkspacePath(path), ["POST", "PATCH", "PUT", "DELETE"].contains(method) else { throw Failure.invalidResponse }
        // 保留官方字段名；这里不使用 convertToSnakeCase，以免动态键被再次转换。
        return try await request(TradeValue.self, path: path, method: method, body: JSONEncoder().encode(TradeValue.object(fields)))
    }
    static func allowedWorkspacePath(_ path: String) -> Bool {
        path.range(of: #"^/api/(common/[A-Za-z0-9_/-]+|auth/(me|logout)|agent/(waiting|publish-requests)(/[0-9]+/(take|decision))?)$"#,
                   options: .regularExpression) != nil && !path.contains("..") && !path.contains("//")
    }
    func uploadImage(_ data: Data, conversationID: Int64) async throws -> TradeValue {
        guard data.count <= 10 * 1024 * 1024, !data.isEmpty, conversationID > 0 else { throw Failure.invalidResponse }
        let boundary = "TradeImage-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await request(TradeValue.self, path: "/api/common/conversations/\(conversationID)/attachments", method: "POST",
                                 body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
    func image(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: URL(string: "https://agent-api.nodeseek.org"))?.absoluteURL,
              url.scheme == "https", url.host == "agent-api.nodeseek.org", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/api/") || url.path.hasPrefix("/uploads/") else { throw Failure.invalidResponse }
        let target = url.path + (url.query.map { "?" + $0 } ?? "")
        return try await request(TradeImageResponse.self, path: target).data
    }
}

// 图片以原始字节返回，继续使用同一签名和重定向隔离策略。
struct TradeImageResponse: Decodable {
    let data: Data
    init(data: Data) { self.data = data }
    init(from decoder: Decoder) throws { throw TradeAPIClient.Failure.invalidResponse }
}
