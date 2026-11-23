import CryptoKit
import Foundation
import WebKit

enum TradeText {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Trade", comment: "")
    }
}

struct TradeUser: Decodable, Identifiable, Equatable {
    let id: Int64
    let username: String
    var role: String? = nil
}

struct TradeConversation: Decodable, Identifiable {
    struct Preview: Decodable { let text: String?; var at: String? = nil; var sender: String? = nil }
    struct Summary: Decodable { let stage: String? }
    let id: Int64
    let title: String?
    let status: String?
    let lastMessage: Preview?
    var trade: Summary? = nil
    var unread: Int? = nil
    var myRole: String? = nil
    var createdAt: String? = nil
    var type: String? = nil
    var isPublic: Bool? = nil
    var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? TradeText.text("未命名交易") }
}

struct TradeAmount: Decodable, Equatable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string }
        else { value = NSDecimalNumber(decimal: try container.decode(Decimal.self)).stringValue }
    }
}

struct TradeRoom: Decodable {
    struct Access: Decodable, Equatable {
        let canWrite: Bool; let role: String?
        var canModerate: Bool? = nil
        var canDeleteOthers: Bool? = nil
        var canPin: Bool? = nil
    }
    struct Progress: Decodable, Equatable {
        let id: Int64
        let stage: String
        let progressStep: Int?
        let steps: [Step]?
        var title: String? = nil
        var version: Int? = nil
        var price: TradeAmount? = nil
        var agentFee: TradeAmount? = nil
        var feePayer: String? = nil
        var deliveryMethod: String? = nil
        var postUrl: String? = nil
        var brand: String? = nil
        var priceNote: String? = nil
        var agentFeeNote: String? = nil
        var buyerConfirmedAt: String? = nil
        var sellerConfirmedAt: String? = nil
        var unlockBuyerAt: String? = nil
        var unlockSellerAt: String? = nil
        var freeChatAt: String? = nil
        var proposal: Proposal? = nil
        var escrowTaskId: Int64? = nil
        var redPacket: RedPacket? = nil
        var settlement: Settlement? = nil
        var feePolicy: FeePolicy? = nil
        var resetAt: String? = nil
        var brandId: Int64? = nil
    }
    struct Settlement: Decodable, Equatable {
        var buyerFee: TradeAmount? = nil; var sellerFee: TradeAmount? = nil
        var buyerPays: TradeAmount? = nil; var sellerGets: TradeAmount? = nil
        var buyerText: String? = nil; var sellerText: String? = nil
    }
    struct FeePolicy: Decodable, Equatable {
        var agentName: String? = nil; var rate: TradeAmount? = nil
        var min: TradeAmount? = nil; var cap: TradeAmount? = nil
    }
    struct Proposal: Decodable, Equatable {
        var kind: String? = nil; var by: Int64? = nil
        var buyerAt: String? = nil; var sellerAt: String? = nil; var agentAt: String? = nil
    }
    struct RedPacket: Decodable, Equatable { var amount: TradeAmount? = nil }
    struct Step: Decodable, Equatable {
        let key: String
        let label: String?
        let title: String?
        var roles: [String]? = nil
    }
    struct Member: Decodable, Equatable {
        let role: String
        var id: Int64? = nil
        var username: String? = nil
    }
    let conversation: TradeConversation
    let access: Access
    let trade: Progress?
    let members: [Member]?
    var risk: TradeValue? = nil
    var publishRequest: TradeValue? = nil

    var canInvite: Bool {
        let roles = Set(["buyer", "seller", "agent"])
        return conversation.status == "open" && trade?.stage == "draft" && roles.contains(access.role ?? "")
            && !roles.isSubset(of: Set((members ?? []).map(\.role)))
    }
}

struct TradeMessage: Decodable, Identifiable {
    struct Reply: Decodable {
        let id: Int64; var content: String? = nil; var sender: TradeUser? = nil
        var hidden: Bool? = nil; var deleted: Bool? = nil
    }
    let id: Int64
    let sender: TradeUser?
    let content: String?
    let createdAt: String?
    let type: String?
    var replyTo: Reply? = nil
    var replyToId: Int64? = nil
    var imageUrl: String? = nil
    var visibleTo: [TradeUser]? = nil
    var hidden: Bool? = nil
    var deleted: Bool? = nil
    var editCount: Int? = nil
    var editsVisible: Bool? = nil
    var pinnedAt: String? = nil
    var reactions: [TradeValue]? = nil
    var quoteText: String? = nil
    var deletionVisible: Bool? = nil
    var meta: TradeValue? = nil
}

struct TradeInvitation: Decodable {
    struct Role: Decodable, Identifiable {
        let role: String
        let allowed: Bool
        let takenBy: String?
        var id: String { role }
    }
    let conversationId: Int64
    let kind: String
    let trade: TradeRoom.Progress
    let roles: [Role]?
    let myRole: String?

    var isMember: Bool { myRole != nil && myRole != "observer" }
    var availableRoles: [Role] { (roles ?? []).filter { $0.allowed && $0.takenBy == nil } }
}

struct TradeMessagePage: Decodable {
    let messages: [TradeMessage]
    let hasMore: Bool
}

enum TradeRole: String, CaseIterable, Identifiable {
    case buyer, seller
    var id: Self { self }
    var title: String { TradeText.text(self == .buyer ? "买家" : "卖家") }
}

@MainActor
protocol TradeServing: AnyObject {
    func currentUser() async throws -> TradeUser?
    func conversations() async throws -> [TradeConversation]
    func agents() async throws -> [TradeUser]
    func create(title: String, role: TradeRole, agentID: Int64) async throws -> Int64
    func room(id: Int64) async throws -> TradeRoom
    func messages(id: Int64, before: Int64?) async throws -> TradeMessagePage
    func send(_ text: String, to id: Int64) async throws -> TradeMessage
    func invitation(for tradeID: Int64) async throws -> URL
    func invitation(token: String) async throws -> TradeInvitation
    func join(token: String, role: String?) async throws -> Int64
    func perform(_ action: TradeAction, tradeID: Int64) async throws
    func updateTerms(_ terms: TradeTerms, tradeID: Int64) async throws
    func markRead(conversationID: Int64, messageID: Int64) async throws
    func send(_ text: String, to id: Int64, replyingTo: Int64) async throws -> TradeMessage
}

@MainActor
final class TradeAPIClient: TradeServing {
    static let webURL = URL(string: "https://agent.nodeseek.org/")!
    private static let apiHost = "agent-api.nodeseek.org"
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    enum Failure: LocalizedError, Equatable {
        case signInRequired, invalidResponse, rejected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .signInRequired: TradeText.text("请先登录交易系统")
            case .invalidResponse: TradeText.text("无法读取交易数据，请稍后重试。")
            case .rejected: TradeText.text("交易系统未接受此请求，请刷新后确认结果。")
            case .server(let message): message
            }
        }
    }

    private struct SigningResponse: Decodable { let kid: String; let key: String; let serverTime: Double }
    private struct SigningSession {
        let kid: String
        let key: SymmetricKey
        let timeOffset: Double
        var expiry: Double { Double(kid.split(separator: ".").first ?? "") ?? 0 }
    }
    private struct UserResponse: Decodable { let user: TradeUser? }
    private struct RoomsResponse: Decodable { let conversations: [TradeConversation] }
    private struct AgentsResponse: Decodable { let agents: [TradeUser] }
    private struct CreatedResponse: Decodable { let conversationId: Int64 }
    private struct MessageResponse: Decodable { let message: TradeMessage }
    private struct CreateBody: Encodable { let role: String; let title: String; let agentUserId: Int64 }
    private struct MessageBody: Encodable { let content: String; var replyToId: Int64? = nil }
    private struct InviteResponse: Decodable { let token: String }
    private struct ErrorResponse: Decodable { let code: String?; let error: String? }

    private let transport: Transport
    private let cookies: () async -> [HTTPCookie]
    private let storeCookies: ([HTTPCookie]) async -> Void
    private let now: () -> Date
    private var signingSession: SigningSession?

    init(transport: Transport? = nil, cookies: (() async -> [HTTPCookie])? = nil,
         storeCookies: (([HTTPCookie]) async -> Void)? = nil, now: @escaping () -> Date = Date.init) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: TradeRedirectPolicy(), delegateQueue: nil)
        self.transport = transport ?? { try await session.data(for: $0) }
        self.cookies = cookies ?? { await WKWebsiteDataStore.default().httpCookieStore.allCookies() }
        self.storeCookies = storeCookies ?? { cookies in
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in cookies { await store.setCookie(cookie) }
        }
        self.now = now
    }

    func currentUser() async throws -> TradeUser? {
        try await request(UserResponse.self, path: "/api/auth/me").user
    }

    func conversations() async throws -> [TradeConversation] {
        try await request(RoomsResponse.self, path: "/api/common/conversations?type=trade").conversations
    }

    func agents() async throws -> [TradeUser] {
        try await request(AgentsResponse.self, path: "/api/common/agents").agents
    }

    func create(title: String, role: TradeRole, agentID: Int64) async throws -> Int64 {
        try await request(CreatedResponse.self, path: "/api/common/trades", method: "POST",
                          body: encode(CreateBody(role: role.rawValue, title: title, agentUserId: agentID))).conversationId
    }

    func room(id: Int64) async throws -> TradeRoom {
        try await request(TradeRoom.self, path: "/api/common/conversations/\(id)")
    }

    func messages(id: Int64, before: Int64? = nil) async throws -> TradeMessagePage {
        let cursor = before.map { "&before_id=\($0)" } ?? ""
        return try await request(TradeMessagePage.self, path: "/api/common/conversations/\(id)/messages?limit=50\(cursor)")
    }

    func send(_ text: String, to id: Int64) async throws -> TradeMessage {
        try await request(MessageResponse.self, path: "/api/common/conversations/\(id)/messages", method: "POST",
                          body: encode(MessageBody(content: text))).message
    }

    func invitation(for tradeID: Int64) async throws -> URL {
        let result = try await request(InviteResponse.self, path: "/api/common/trades/\(tradeID)/invites", method: "POST",
                                       body: encode(["kind": "participant"]))
        guard !result.token.isEmpty, result.token.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }) else { throw Failure.invalidResponse }
        return Self.webURL.appendingPathComponent("chat/invite").appendingPathComponent(result.token)
    }

    func invitation(token: String) async throws -> TradeInvitation {
        guard TradeInvitationLink.isValidToken(token) else { throw Failure.invalidResponse }
        return try await request(TradeInvitation.self, path: "/api/common/invites/\(token)")
    }

    func join(token: String, role: String?) async throws -> Int64 {
        guard TradeInvitationLink.isValidToken(token) else { throw Failure.invalidResponse }
        return try await request(CreatedResponse.self, path: "/api/common/invites/\(token)/join", method: "POST",
                                 body: encode(role.map { ["role": $0] } ?? [:])).conversationId
    }

    func perform(_ action: TradeAction, tradeID: Int64) async throws {
        let body = action.step.map { ["step": $0] } ?? [:]
        _ = try await request(TradeMutationResponse.self, path: "/api/common/trades/\(tradeID)/\(action.endpoint)",
                              method: "POST", body: encode(body))
    }

    func markRead(conversationID: Int64, messageID: Int64) async throws {
        _ = try await request(TradeMutationResponse.self, path: "/api/common/conversations/\(conversationID)/read", method: "POST",
                              body: encode(["message_id": messageID]))
    }

    func updateTerms(_ terms: TradeTerms, tradeID: Int64) async throws {
        _ = try await request(TradeMutationResponse.self, path: "/api/common/trades/\(tradeID)", method: "PATCH", body: encode(terms))
    }

    func send(_ text: String, to id: Int64, replyingTo: Int64) async throws -> TradeMessage {
        try await request(MessageResponse.self, path: "/api/common/conversations/\(id)/messages", method: "POST",
                          body: encode(MessageBody(content: text, replyToId: replyingTo))).message
    }

    private struct TradeMutationResponse: Decodable {}

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func makeRequest(path: String, method: String) async -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(Self.apiHost)\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://agent.nodeseek.org", forHTTPHeaderField: "Origin")
        request.setValue("nTrade", forHTTPHeaderField: "X-Application")
        let requestPath = request.url?.path ?? ""
        let scoped = await cookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            return (domain == Self.apiHost || domain == ".\(Self.apiHost)" || domain == ".nodeseek.org")
                && (cookie.expiresDate.map { $0 > now() } ?? true)
                && (requestPath == cookie.path || requestPath.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: scoped) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func signing() async throws -> SigningSession {
        if let signingSession, signingSession.expiry - (now().timeIntervalSince1970 * 1_000 + signingSession.timeOffset) > 60_000 {
            return signingSession
        }
        let request = await makeRequest(path: "/edge-api/auth/sign-key", method: "POST")
        let (data, response) = try await transport(request)
        await captureCookies(from: response)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? decoder.decode(SigningResponse.self, from: data) else { throw Failure.invalidResponse }
        let normalized = value.key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let key = Data(base64Encoded: padded), !key.isEmpty else { throw Failure.invalidResponse }
        let result = SigningSession(kid: value.kid, key: SymmetricKey(data: key), timeOffset: value.serverTime - now().timeIntervalSince1970 * 1_000)
        signingSession = result
        return result
    }

    private func captureCookies(from response: URLResponse) async {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, url.scheme == "https", url.host == Self.apiHost,
              url.port == nil || url.port == 443 else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { headers, entry in
            if let name = entry.key as? String, let value = entry.value as? String { headers[name] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter {
            let domain = $0.domain.lowercased()
            return domain == Self.apiHost || domain == ".\(Self.apiHost)" || domain == ".nodeseek.org"
        }
        // 原生请求和授权网页共用同一份会话，也保存续期、轮换和退出产生的 Cookie。
        if !cookies.isEmpty { await storeCookies(cookies) }
    }

    func request<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil, mayRefreshSignature: Bool = true, contentType: String = "application/json") async throws -> T {
        let signing = try await signing()
        var request = await makeRequest(path: path, method: method)
        let stamp = String(Int64(now().timeIntervalSince1970 * 1_000 + signing.timeOffset))
        let signature = HMAC<SHA256>.authenticationCode(for: Data("v1\n\(method)\n\(path)\n\(stamp)".utf8), using: signing.key)
        request.setValue(signing.kid, forHTTPHeaderField: "X-Sign-Kid")
        request.setValue(stamp, forHTTPHeaderField: "X-Sign-Ts")
        request.setValue(Data(signature).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""), forHTTPHeaderField: "X-Sign")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport(request)
        await captureCookies(from: response)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.invalidResponse }
        if status == 401 {
            if (try? decoder.decode(ErrorResponse.self, from: data))?.code == "sign_invalid" {
                signingSession = nil
                if method == "GET", mayRefreshSignature {
                    return try await self.request(type, path: path, mayRefreshSignature: false)
                }
                throw Failure.rejected
            }
            throw Failure.signInRequired
        }
        guard (200...299).contains(status) else {
            if let message = (try? decoder.decode(ErrorResponse.self, from: data))?.error,
               !message.isEmpty, message.count <= 500 { throw Failure.server(message) }
            throw Failure.rejected
        }
        if type == TradeImageResponse.self {
            guard data.count <= 20 * 1024 * 1024 else { throw Failure.invalidResponse }
            return TradeImageResponse(data: data) as! T
        }
        // 删除等写入可能返回 204；空成功响应仍算成功，避免误导用户重复提交。
        let payload = data.isEmpty ? Data("{}".utf8) : data
        if type == TradeValue.self {
            return try JSONDecoder().decode(type, from: payload)
        }
        guard let value = try? decoder.decode(type, from: payload) else { throw Failure.invalidResponse }
        return value
    }
}

final class TradeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
