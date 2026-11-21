import Foundation
import Testing
@testable import nodeseek

@MainActor
struct TradeNativeTests {
    @Test func signedTransportScopesCookiesAndEncodesCreateFields() async throws {
        var requests: [URLRequest] = []
        let api = TradeAPIClient(transport: { request in
            requests.append(request)
            let body = request.url?.path == "/edge-api/auth/sign-key"
                ? #"{"kid":"2000000600000.test","key":"dGVzdA","server_time":2000000000000}"#
                : #"{"conversation_id":42}"#
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }, cookies: {
            [Self.cookie(named: "agent", domain: "agent-api.nodeseek.org", path: "/"),
             Self.cookie(named: "forum", domain: ".nodeseek.com", path: "/"),
             Self.cookie(named: "elsewhere", domain: "agent-api.nodeseek.org", path: "/unrelated")].compactMap { $0 }
        }, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        #expect(try await api.create(title: "Example", role: .seller, agentID: 8) == 42)
        let submission = try #require(requests.last)
        #expect(submission.url?.host == "agent-api.nodeseek.org")
        #expect(submission.url?.path == "/api/common/trades")
        #expect(submission.value(forHTTPHeaderField: "Cookie") == "agent=sample")
        #expect(submission.value(forHTTPHeaderField: "X-Sign-Ts") == "2000000000000")
        #expect(submission.value(forHTTPHeaderField: "X-Sign") == "55pzpYX2ImCbjtRhf9UKfyuC7d02B72QUJCnaBS-_3Q")
        let data = try #require(submission.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["title"] as? String == "Example")
        #expect(body["role"] as? String == "seller")
        #expect(body["agent_user_id"] as? Int == 8)
    }

    @Test func unknownDeliveryKeepsDraftAndDoesNotResubmit() async throws {
        let api = TradeStub()
        let model = TradeRoomModel(id: 42, api: api)
        await model.reload()
        model.draft = "保留草稿"
        api.failSend = true
        await model.send()
        #expect(model.sendNeedsReview)
        #expect(model.draft == "保留草稿")
        await model.send()
        #expect(api.attempts == 1)
        model.acknowledgeSend()
        api.failSend = false
        await model.send()
        #expect(api.attempts == 2)
        #expect(model.draft.isEmpty)
        #expect(model.messages.map(\.id) == [9])
    }

    @Test func signedOutHomeDoesNotFetchPrivateData() async {
        let api = TradeStub()
        let model = TradeHomeModel(api: api)
        await model.load()
        #expect(model.state == .signedOut)
        #expect(api.conversationRequests == 0)
    }

    private static func cookie(named name: String, domain: String, path: String) -> HTTPCookie? {
        HTTPCookie(properties: [.name: name, .value: "sample", .domain: domain, .path: path, .secure: "TRUE"])
    }
}

@MainActor
private final class TradeStub: TradeServing {
    var failSend = false
    var attempts = 0
    var conversationRequests = 0

    func currentUser() async throws -> TradeUser? { nil }
    func conversations() async throws -> [TradeConversation] { conversationRequests += 1; return [] }
    func agents() async throws -> [TradeUser] { [] }
    func create(title: String, role: TradeRole, agentID: Int64) async throws -> Int64 { 42 }

    func room(id: Int64) async throws -> TradeRoom {
        TradeRoom(conversation: TradeConversation(id: id, title: nil, status: "open", lastMessage: nil),
                  access: .init(canWrite: true, role: "seller"), trade: nil, members: nil)
    }

    func messages(id: Int64, before: Int64?) async throws -> TradeMessagePage { .init(messages: [], hasMore: false) }

    func send(_ text: String, to id: Int64) async throws -> TradeMessage {
        attempts += 1
        if failSend { throw URLError(.timedOut) }
        return .init(id: 9, sender: nil, content: text, createdAt: nil, type: "text")
    }

    func invitation(for tradeID: Int64) async throws -> URL { TradeAPIClient.webURL }
}
