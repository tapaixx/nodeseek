import Foundation
import Testing
import UIKit
import WebKit
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

    @Test func renewedCookiesAreReusedByANewNativeClient() async throws {
        var jar: [HTTPCookie] = []
        var requests: [URLRequest] = []
        let transport: TradeAPIClient.Transport = { request in
            requests.append(request)
            let signing = request.url?.path == "/edge-api/auth/sign-key"
            let body = signing ? #"{"kid":"2000000600000.test","key":"dGVzdA","server_time":2000000000000}"#
                : #"{"user":{"id":7,"username":"sample"}}"#
            let headers = signing ? nil : ["Set-Cookie": "trade_session=renewed; Path=/; Expires=Fri, 01 Jan 2100 00:00:00 GMT; Secure; HttpOnly"]
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }
        func client() -> TradeAPIClient {
            TradeAPIClient(transport: transport, cookies: { jar }, storeCookies: { jar = $0 })
        }
        #expect(try await client().currentUser()?.id == 7)
        #expect(jar.map(\.name) == ["trade_session"])
        #expect(try await client().currentUser()?.id == 7)
        #expect(requests.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "trade_session=renewed" })
    }

    @Test func responseCookieScopeCannotOverwriteForumSession() async throws {
        var stored: [HTTPCookie] = []
        let api = TradeAPIClient(transport: { request in
            let signing = request.url?.path == "/edge-api/auth/sign-key"
            let body = signing ? #"{"kid":"2000000600000.test","key":"dGVzdA","server_time":2000000000000}"# : #"{"user":null}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "forum=untrusted; Domain=.nodeseek.com; Path=/; Secure"])!
            return (Data(body.utf8), response)
        }, cookies: { [] }, storeCookies: { stored += $0 }, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        #expect(try await api.currentUser() == nil)
        #expect(stored.isEmpty)
    }

    @Test func expiredCookieIsCapturedEvenWhenServerRequiresSignIn() async throws {
        var stored: [HTTPCookie] = []
        let api = TradeAPIClient(transport: { request in
            let signing = request.url?.path == "/edge-api/auth/sign-key"
            let body = signing ? #"{"kid":"2000000600000.test","key":"dGVzdA","server_time":2000000000000}"# : #"{"error":"unauthorized"}"#
            let headers = signing ? nil : ["Set-Cookie": "trade_session=; Path=/; Max-Age=0; Secure; HttpOnly"]
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: signing ? 200 : 401,
                                                   httpVersion: nil, headerFields: headers)!)
        }, cookies: { [] }, storeCookies: { stored += $0 }, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        await #expect(throws: TradeAPIClient.Failure.signInRequired) { try await api.currentUser() }
        #expect(stored.count == 1)
        #expect(stored.first?.name == "trade_session")
        #expect((stored.first?.expiresDate ?? .distantFuture) <= Date())
    }

    @Test func loginReusesRecoveredSessionWithoutOpeningConnect() async {
        let api = TradeStub()
        let model = TradeHomeModel(api: api)
        await model.load()
        #expect(model.state == .signedOut)
        var connectCount = 0
        model.onLogin = { connectCount += 1 }
        api.user = TradeUser(id: 7, username: "sample")
        await model.signIn()
        #expect(model.state == .ready)
        #expect(connectCount == 0)
    }

    @Test func concurrentLoginTapsOnlyRequestOneAuthorization() async throws {
        let api = TradeStub()
        let model = TradeHomeModel(api: api)
        var connectCount = 0
        model.onLogin = { connectCount += 1 }
        var lookup: CheckedContinuation<TradeUser?, any Error>?
        api.lookupUser = { try await withCheckedThrowingContinuation { lookup = $0 } }
        let first = Task { await model.signIn() }
        while lookup == nil { await Task.yield() }
        await model.signIn()
        let pending = try #require(lookup)
        pending.resume(returning: nil)
        await first.value
        #expect(connectCount == 1)
        #expect(!model.isCheckingSignIn)
    }

    @Test func networkFailureDoesNotRequestConnect() async {
        let api = TradeStub()
        let model = TradeHomeModel(api: api)
        var connectCount = 0
        model.onLogin = { connectCount += 1 }
        api.lookupUser = { throw URLError(.notConnectedToInternet) }
        await model.signIn()
        #expect(model.state == .failed)
        #expect(connectCount == 0)
    }

    @Test func chatReturnRouteRequiresConfirmedNativeSession() async throws {
        var isSignedIn = false
        var checks = 0
        var completions = 0
        let controller = TradeAuthorizationViewController(automaticallyLoadsPage: false, verifySession: {
            checks += 1
            return isSignedIn
        }, onAuthorized: { completions += 1 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        let navigation = UINavigationController(rootViewController: controller)
        host.present(navigation, animated: false)
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
        }
        // 本地空白文档模拟官方回跳，不访问 connect，也不使用真实账户。
        controller.webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://agent.nodeseek.org/chat/"))
        var deadline = Date().addingTimeInterval(5)
        while controller.presentedViewController == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(checks == 1)
        #expect(completions == 0)
        #expect(host.presentedViewController === navigation)
        let hint = try #require(controller.presentedViewController as? UIAlertController)
        deadline = Date().addingTimeInterval(3)
        while hint.isBeingPresented, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(!hint.isBeingPresented)
        await withCheckedContinuation { continuation in
            hint.dismiss(animated: false) { continuation.resume() }
        }
        isSignedIn = true
        controller.webView(controller.webView, didFinish: nil)
        deadline = Date().addingTimeInterval(3)
        while completions == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(checks == 2)
        #expect(completions == 1)
        #expect(host.presentedViewController == nil)
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
    var user: TradeUser?
    var lookupUser: (() async throws -> TradeUser?)?

    func currentUser() async throws -> TradeUser? {
        if let lookupUser { return try await lookupUser() }
        return user
    }
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
