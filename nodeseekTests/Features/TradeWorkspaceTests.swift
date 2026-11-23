import Foundation
import Testing
@testable import nodeseek

@MainActor
struct TradeWorkspaceTests {
    @Test func dynamicValuesPreserveOfficialKeysAndDecimalAmounts() throws {
        let value = try JSONDecoder().decode(TradeValue.self, from: Data(#"{"can_view_goods":false,"price":"100.50","amount":0.1,"user":{"role":"user"},"items":[],"empty":null}"#.utf8))
        #expect(!value["can_view_goods"].flag)
        #expect(value["price"].text == "100.50")
        #expect(value["amount"].text == "0.1")
        #expect(value["empty"].isNull)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(object["can_view_goods"] as? Bool == false)
        #expect(object["canViewGoods"] == nil)
    }

    @Test func workspacePathsRejectTraversalAndUnrelatedServices() {
        for path in ["/api/common/escrow/8", "/api/common/points/packets", "/api/agent/waiting/8/take", "/api/common/messages/8/reactions"] {
            #expect(TradeAPIClient.allowedWorkspacePath(path))
        }
        for path in ["https://evil.org/api/common/me", "//evil.org/api/common/me", "/api/common/../auth/me", "/api/common/me?x=1", "/api/common/%2e%2e", "/api/panels/admin/key", "/api/admin/users"] {
            #expect(!TradeAPIClient.allowedWorkspacePath(path))
        }
    }

    @Test func signedWorkspaceQueryEscapesUserInputAnd204IsSuccessful() async throws {
        var requests: [URLRequest] = []
        let api = TradeAPIClient(transport: { request in
            requests.append(request)
            if request.url?.path == "/edge-api/auth/sign-key" {
                return (Data(#"{"kid":"2000000600000.test","key":"dGVzdA","server_time":2000000000000}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let data = request.httpMethod == "DELETE" ? Data() : Data(#"{"can_view_goods":false}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "DELETE" ? 204 : 200, httpVersion: nil, headerFields: nil)!)
        }, cookies: { [] }, storeCookies: { _ in }, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        let result = try await api.read("/api/common/users/search", query: ["q": "名字 & admin=true"])
        #expect(!result["can_view_goods"].flag)
        let parts = try #require(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.count == 1)
        #expect(parts.queryItems?.first?.value == "名字 & admin=true")
        _ = try await api.write("/api/common/quick-messages/8", method: "DELETE", fields: [:])
        _ = try await api.read("/api/common/agents", query: [:])
        #expect(requests.count == 4)
        #expect(requests.last?.url?.absoluteString == "https://agent-api.nodeseek.org/api/common/agents")
    }

    @Test func unknownWriteResultCannotBeSubmittedTwice() async {
        let api = WorkspaceStub()
        api.failWrite = true
        let operation = TradeOperation(title: "sample", explanation: "sample", path: "/api/common/feedback", inputs: [.init(key: "content", title: "sample", required: true)])
        let model = TradeOperationModel(operation: operation, api: api)
        model.values["content"] = "test"
        await model.submit()
        await model.submit()
        #expect(api.writes.count == 1)
        #expect(model.attempted)
        #expect(model.error != nil)
    }

    @Test func changedServerSnapshotPreventsIrreversibleOperation() async {
        let api = WorkspaceStub()
        api.response = .object(["task": .object(["can_cancel": .bool(false)])])
        let operation = TradeOperation(title: "cancel", explanation: "sample", path: "/api/common/escrow/8/cancel", irreversible: true,
            guardPath: "/api/common/escrow/8", guardValue: .object(["task": .object(["can_cancel": .bool(true)])]))
        let model = TradeOperationModel(operation: operation, api: api)
        await model.submit()
        #expect(api.writes.isEmpty)
        #expect(model.error != nil)
    }

    @Test func creationSupportsOptionalTitleAndNotifyingAllAgents() async {
        let api = WorkspaceStub()
        let operation = TradeForms.create(agents: [], selectedAgent: "all", userRole: "user")
        let model = TradeOperationModel(operation: operation, api: api)
        #expect(model.valid)
        await model.submit()
        #expect(api.writes.first?.fields["notify_agents"] == .bool(true))
        #expect(api.writes.first?.fields["agent_user_id"] == nil)
        #expect(api.writes.first?.fields["title"] == nil)
        let roleField = operation.inputs.first { $0.key == "role" }
        if case .choice(let roles) = roleField?.kind { #expect(!roles.contains { $0.value == "agent" }) }
        else { Issue.record("Missing role picker") }
    }

    @Test func pointsUseNumericAmountsAndRejectZero() async {
        let api = WorkspaceStub()
        let operation = TradeOperation(title: "packet", explanation: "sample", path: "/api/common/points/packets", inputs: [.init(key: "amount", title: "amount", kind: .money, required: true)], fields: ["agent_id": .id(9)])
        let zero = TradeOperationModel(operation: operation, api: api)
        zero.values["amount"] = "0"
        await zero.submit()
        #expect(api.writes.isEmpty)
        let positive = TradeOperationModel(operation: operation, api: api)
        positive.values["amount"] = "12"
        await positive.submit()
        #expect(api.writes.first?.fields["amount"] == .number(12))
    }

    @Test func groupRequestCannotChooseSameRoleForBothParties() async {
        let api = WorkspaceStub()
        let user = TradeValue.object(["id": .id(2), "username": .string("peer"), "role": .string("user")])
        let model = TradeOperationModel(operation: TradeForms.request(user: user, trade: true, userRole: "user"), api: api)
        model.values["from_role"] = "buyer"; model.values["to_role"] = "buyer"
        await model.submit()
        #expect(api.writes.isEmpty)
        #expect(model.error != nil)
    }

    @Test func secretInputsAreRemovedAfterConfirmedSuccess() async {
        let api = WorkspaceStub()
        let operation = TradeOperation(title: "escrow", explanation: "sample", path: "/api/common/escrow", inputs: [.init(key: "goods", title: "secret", kind: .secret, required: true)])
        let model = TradeOperationModel(operation: operation, api: api)
        model.values["goods"] = "private test data"
        await model.submit()
        #expect(model.values["goods"] == "")
        #expect(model.result != nil)
    }

    @Test func privateHiddenMessageNeverBecomesOrdinaryText() throws {
        let data = Data(#"{"id":7,"type":"private_hidden","sender":{"id":1,"username":"sender"},"content":null,"visible_to":[{"id":2,"username":"recipient"}],"meta":null}"#.utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(TradeMessage.self, from: data)
        #expect(message.type == "private_hidden")
        #expect(message.visibleTo?.first?.id == 2)
        #expect(message.content == nil)
    }

    @Test func externalActionLinksRestrictSchemesAndHosts() {
        #expect(TradeExternalURL.allowed("https://t.me/example") != nil)
        #expect(TradeExternalURL.allowed("https://openapi.alipay.com/pay") != nil)
        for raw in ["javascript:alert(1)", "http://t.me/example", "https://t.me.evil.org/", "https://user@t.me/example", "https://evil.org/pay"] {
            #expect(TradeExternalURL.allowed(raw) == nil)
        }
    }
}

@MainActor
final class WorkspaceStub: TradeWorkspaceServing {
    struct Write { let path: String; let method: String; let fields: [String: TradeValue] }
    var response: TradeValue = .object([:])
    var failWrite = false
    var writes: [Write] = []
    func read(_ path: String, query: [String: String]) async throws -> TradeValue { response }
    func write(_ path: String, method: String, fields: [String: TradeValue]) async throws -> TradeValue {
        writes.append(.init(path: path, method: method, fields: fields))
        if failWrite { throw URLError(.timedOut) }
        return response
    }
    func uploadImage(_ data: Data, conversationID: Int64) async throws -> TradeValue { .object(["id": .id(10)]) }
    func image(_ path: String) async throws -> Data { Data() }
}

extension TradeWorkspaceTests {
    @Test func remainingValueIncludesMoreThanOneBillingCycle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        #expect(TradeRemainingValue.calculate(expiry: end, valuation: start, cycleMonths: 1, price: "10", calendar: calendar) == 30)
        #expect(TradeRemainingValue.calculate(expiry: start, valuation: end, cycleMonths: 1, price: "10", calendar: calendar) == 0)
    }
}


extension TradeWorkspaceTests {
    @Test func selectingAllOnReassignmentExplicitlyClearsDesignatedAgent() async {
        let api = WorkspaceStub()
        let operation = TradeOperation(title: "reassign", explanation: "sample", path: "/api/common/escrow/8/reassign",
            inputs: [.init(key: "agent_user_id", title: "agent", kind: .choice([.init(value: "all", title: "all")]), initial: "all")])
        let model = TradeOperationModel(operation: operation, api: api)
        await model.submit()
        #expect(api.writes.first?.fields["agent_user_id"] == .null)
    }
}

extension TradeWorkspaceTests {
    @Test func pointsPacketsRequireIntegersAndRespectAvailableBalance() async {
        let api = WorkspaceStub()
        let op = TradeOperation(title: "packet", explanation: "sample", path: "/api/common/points/packets",
            inputs: [.init(key: "amount", title: "amount", kind: .money, required: true)], maximumAmount: 20)
        for amount in ["0", "0.5", "20.5", "21"] {
            let model = TradeOperationModel(operation: op, api: api)
            model.values["amount"] = amount
            await model.submit()
            #expect(api.writes.isEmpty)
        }
        let valid = TradeOperationModel(operation: op, api: api)
        valid.values["amount"] = "20"
        await valid.submit()
        #expect(api.writes.count == 1)
    }
}

extension TradeWorkspaceTests {
    @Test func privateMessageUsesOfficialAudienceEnvelopeAndRetainsDraftOnFailure() async throws {
        let api = WorkspaceMessageStub()
        let model = TradeRoomModel(id: 42, api: api)
        await model.reload()
        model.visibility = 3
        model.draft = "private test"
        await model.send()
        #expect(api.fields["visible_to"] == .object(["user_ids": .array([.id(3)])]))
        #expect(model.draft.isEmpty)
        api.fails = true
        model.draft = "retain"
        await model.send()
        #expect(model.sendNeedsReview)
        #expect(model.draft == "retain")
        let calls = api.calls
        await model.send()
        #expect(api.calls == calls)
    }
}

@MainActor
private final class WorkspaceMessageStub: TradeServing, TradeWorkspaceServing {
    var fields: [String: TradeValue] = [:]
    var calls = 0
    var fails = false
    func currentUser() async throws -> TradeUser? { .init(id: 1, username: "buyer") }
    func conversations() async throws -> [TradeConversation] { [] }
    func agents() async throws -> [TradeUser] { [] }
    func create(title: String, role: TradeRole, agentID: Int64) async throws -> Int64 { 42 }
    func room(id: Int64) async throws -> TradeRoom {
        .init(conversation: .init(id: id, title: "sample", status: "open", lastMessage: nil),
              access: .init(canWrite: true, role: "buyer"), trade: nil,
              members: [.init(role: "buyer", id: 1, username: "buyer"), .init(role: "agent", id: 3, username: "agent")])
    }
    func messages(id: Int64, before: Int64?) async throws -> TradeMessagePage { .init(messages: [], hasMore: false) }
    func send(_ text: String, to id: Int64) async throws -> TradeMessage { throw URLError(.unsupportedURL) }
    func send(_ text: String, to id: Int64, replyingTo: Int64) async throws -> TradeMessage { throw URLError(.unsupportedURL) }
    func invitation(for tradeID: Int64) async throws -> URL { TradeAPIClient.webURL }
    func invitation(token: String) async throws -> TradeInvitation { throw URLError(.unsupportedURL) }
    func join(token: String, role: String?) async throws -> Int64 { 42 }
    func perform(_ action: TradeAction, tradeID: Int64) async throws {}
    func updateTerms(_ terms: TradeTerms, tradeID: Int64) async throws {}
    func markRead(conversationID: Int64, messageID: Int64) async throws {}
    func read(_ path: String, query: [String: String]) async throws -> TradeValue { .object([:]) }
    func write(_ path: String, method: String, fields: [String: TradeValue]) async throws -> TradeValue {
        self.fields = fields; calls += 1
        if fails { throw URLError(.timedOut) }
        return .object(["message": .object(["id": .id(10), "content": .string("private test"), "type": .string("text"), "visible_to": .array([.object(["id": .id(3), "username": .string("agent")])])])])
    }
    func uploadImage(_ data: Data, conversationID: Int64) async throws -> TradeValue { .object(["id": .id(5)]) }
    func image(_ path: String) async throws -> Data { Data() }
}

extension TradeWorkspaceTests {
    @Test func embeddedDynamicPermissionsWorkWithTypedDecoder() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(TradeValue.self, from: Data(#"{"requested_by":1,"approver_id":9,"status":"pending"}"#.utf8))
        #expect(value["requested_by"].id == 1)
        #expect(value["approver_id"].id == 9)
    }
}
