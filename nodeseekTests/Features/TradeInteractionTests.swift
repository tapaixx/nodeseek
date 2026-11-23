import Foundation
import SwiftUI
import UIKit
import XCTest
import Testing
@testable import nodeseek

@MainActor
struct TradeInteractionTests {
    private func room(role: String = "buyer", stage: String = "in_progress", step: String = "buyer_paid", version: Int = 1) throws -> TradeRoom {
        let data = Data("""
        {"conversation":{"id":42,"title":"测试交易","status":"open"},"access":{"can_write":true,"role":"\(role)"},
         "trade":{"id":8,"stage":"\(stage)","version":\(version),"progress_step":0,"steps":[{"key":"\(step)","label":"测试进度","roles":["\(role)"]}],
         "title":"测试交易","price":"100.50","agent_fee":5,"fee_payer":"buyer"},
         "members":[{"id":1,"username":"buyer","role":"buyer"},{"id":2,"username":"seller","role":"seller"},{"id":3,"username":"agent","role":"agent"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TradeRoom.self, from: data)
    }

    @Test func actionsFollowRoleStageAndServerStepRoles() throws {
        #expect(try room().availableActions == [.buyerPaid])
        #expect(try room(role: "seller", stage: "finalized").availableActions == [.confirm, .reject])
        #expect(try room(role: "agent", stage: "draft").availableActions == [.finalize])
        #expect(try room(role: "observer").availableActions.isEmpty)
        #expect(try room(stage: "completed").availableActions.isEmpty)
        #expect(try room(step: "new_server_step").availableActions.isEmpty)
    }

    @Test func pausedClosedAndUnauthorizedTradesCannotAdvance() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let base = #"{"conversation":{"id":42,"status":"open"},"access":{"can_write":true,"role":"buyer"},"trade":{"id":8,"stage":"in_progress","progress_step":0,"steps":[{"key":"buyer_paid","roles":["buyer"]}]},"members":[]}"#
        let variants = [
            base.replacingOccurrences(of: #""status":"open""#, with: #""status":"closed""#),
            base.replacingOccurrences(of: #""can_write":true"#, with: #""can_write":false"#),
            base.replacingOccurrences(of: #""progress_step":0"#, with: #""progress_step":9"#),
            base.replacingOccurrences(of: #""roles":["buyer"]"#, with: #""roles":["seller"]"#),
            base.replacingOccurrences(of: #""stage":"in_progress""#, with: #""stage":"in_progress","proposal":{"kind":"reset"}"#),
            base.replacingOccurrences(of: #""stage":"in_progress""#, with: #""stage":"in_progress","free_chat_at":"2026-11-23T00:00:00Z""#),
            base.replacingOccurrences(of: #""stage":"in_progress""#, with: #""stage":"in_progress","red_packet":{"amount":"100"}"#)
        ]
        for json in variants {
            #expect(try decoder.decode(TradeRoom.self, from: Data(json.utf8)).availableActions.isEmpty)
        }
    }

    @Test func termsAcceptDecimalAmountsAndRejectUnsafeLinks() {
        #expect(TradeTerms.amount("12,50", locale: Locale(identifier: "de_DE")) == "12.5")
        #expect(TradeTerms.amount("12.50", locale: Locale(identifier: "en_US")) == "12.5")
        for raw in ["-1", "NaN", "1e3", "1.001", "1,000.00", "", "1000000000000"] {
            #expect(TradeTerms.amount(raw, locale: Locale(identifier: "en_US")) == nil)
        }
        #expect(TradePresentation.postURL("https://www.nodeseek.com/post-123-1") != nil)
        #expect(TradePresentation.postURL("https://www.nodeseek.com.evil.org/post-123-1") == nil)
    }

    @Test func invitationLinksRequireOfficialHostAndOpaqueToken() {
        #expect(TradeInvitationLink.token(from: " https://agent.nodeseek.org/chat/invite/abc_123-XYZ ") == "abc_123-XYZ")
        for raw in ["http://agent.nodeseek.org/chat/invite/abc", "https://agent.nodeseek.org.evil.org/chat/invite/abc",
                    "https://user@agent.nodeseek.org/chat/invite/abc", "https://agent.nodeseek.org:444/chat/invite/abc",
                    "https://agent.nodeseek.org/chat/invite/a/b", "https://agent.nodeseek.org/chat/invite/a?x=1",
                    "https://agent.nodeseek.org/chat/invite/%2E%2E", "abc"] {
            #expect(TradeInvitationLink.token(from: raw) == nil)
        }
    }

    @Test func changedTermsPreventPreviouslyConfirmedAction() async throws {
        let original = try room()
        let api = InteractionStub(detail: try room(version: 2))
        let model = TradeRoomModel(id: 42, api: api)
        await model.perform(.buyerPaid, confirmedRoom: original)
        #expect(api.actionCalls == 0)
        #expect(model.room?.trade?.version == 2)
        #expect(model.notice != nil)
    }

    @Test func unknownActionResultLocksResubmissionUntilReviewed() async throws {
        let detail = try room()
        let api = InteractionStub(detail: detail)
        api.failAction = true
        let model = TradeRoomModel(id: 42, api: api)
        await model.perform(.buyerPaid, confirmedRoom: detail)
        #expect(model.actionNeedsReview)
        await model.perform(.buyerPaid, confirmedRoom: detail)
        #expect(api.actionCalls == 1)
        model.acknowledgeAction()
        api.failAction = false
        await model.perform(.buyerPaid, confirmedRoom: detail)
        #expect(api.actionCalls == 2)
    }

    @Test func readFailureDoesNotPreventSendingAndRetriesAfterward() async throws {
        let api = InteractionStub(detail: try room())
        api.failRead = true
        let model = TradeRoomModel(id: 42, api: api)
        model.isVisible = true
        await model.reload()
        await model.markRead(through: 10)
        model.draft = "hello"
        await model.send()
        #expect(api.sentReplies.count == 1)
        #expect(!model.sendNeedsReview)
        api.failRead = false
        await model.markRead(through: 10)
        await model.markRead(through: 10)
        #expect(api.readCalls == 2)
    }

    @Test func replyTargetIsSentAndDraftSurvivesFailure() async throws {
        let api = InteractionStub(detail: try room())
        let model = TradeRoomModel(id: 42, api: api)
        await model.reload()
        model.reply = model.messages.first
        model.draft = "reply"
        api.failSend = true
        await model.send()
        #expect(model.reply?.id == 10)
        #expect(model.draft == "reply")
        #expect(api.sentReplies == [10])
        model.acknowledgeSend()
        api.failSend = false
        await model.send()
        #expect(model.reply == nil)
        #expect(model.draft.isEmpty)
    }

    @Test func agentFailureDoesNotHideExistingTradesAndFiltersWork() async throws {
        let api = InteractionStub(detail: try room())
        let model = TradeHomeModel(api: api)
        await model.load()
        #expect(model.state == .ready)
        #expect(model.agentFailure)
        #expect(model.conversations.count == 1)
        model.filter = .unread
        #expect(model.filteredConversations.count == 1)
        model.query = "missing"
        #expect(model.filteredConversations.isEmpty)
        model.query = "42"
        #expect(model.filteredConversations.count == 1)
        model.filter = .closed
        #expect(model.filteredConversations.isEmpty)
    }

    @Test func invitationJoinIsNeverAutomaticallyRetried() async throws {
        let api = InteractionStub(detail: try room(stage: "draft"))
        let model = TradeInvitationModel(api: api)
        model.link = "https://agent.nodeseek.org/chat/invite/sample"
        await model.preview()
        model.role = "seller"
        #expect(await model.join() == nil)
        #expect(api.joinCalls == 0)
        model.role = "buyer"
        #expect(await model.join() == nil)
        #expect(model.needsReview)
        #expect(await model.join() == nil)
        #expect(api.joinCalls == 1)
        await model.preview()
        #expect(!model.needsReview)
    }

    @Test func newEndpointsUseOfficialPathsAndVersionedPayloads() async throws {
        var requests: [URLRequest] = []
        let api = TradeAPIClient(transport: { request in
            requests.append(request)
            let body = request.url?.path == "/edge-api/auth/sign-key"
                ? #"{"kid":"2000000600000.test","key":"dGVzdA","server_time":2000000000000}"#
                : request.url?.path.hasSuffix("/join") == true ? #"{"conversation_id":42}"#
                : request.url?.path.hasSuffix("/messages") == true ? #"{"message":{"id":11,"content":"reply"}}"# : "{}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, cookies: { [] }, storeCookies: { _ in }, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        try await api.perform(.buyerPaid, tradeID: 8)
        try await api.updateTerms(TradeTerms(version: 7, title: "terms", price: "10.50", agentFee: nil, feePayer: "split", postUrl: nil), tradeID: 8)
        #expect(try await api.join(token: "sample", role: "buyer") == 42)
        _ = try await api.send("reply", to: 42, replyingTo: 10)
        try await api.markRead(conversationID: 42, messageID: 11)
        let mutations = Array(requests.dropFirst())
        #expect(mutations.map { $0.url!.path } == ["/api/common/trades/8/progress", "/api/common/trades/8", "/api/common/invites/sample/join", "/api/common/conversations/42/messages", "/api/common/conversations/42/read"])
        let patchData = try #require(mutations[1].httpBody)
        let patch = try #require(JSONSerialization.jsonObject(with: patchData) as? [String: Any])
        #expect(patch["version"] as? Int == 7)
        #expect(patch["agent_fee"] is NSNull)
        #expect(patch["price_currency"] as? String == "CNY")
        let replyData = try #require(mutations[3].httpBody)
        let reply = try #require(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        #expect(reply["reply_to_id"] as? Int == 10)
    }
}

@MainActor
final class InteractionStub: TradeServing {
    let detail: TradeRoom
    var actionCalls = 0
    var readCalls = 0
    var joinCalls = 0
    var failAction = false
    var failRead = false
    var failSend = false
    var sentReplies: [Int64?] = []
    init(detail: TradeRoom) { self.detail = detail }
    func currentUser() async throws -> TradeUser? { .init(id: 1, username: "buyer") }
    func conversations() async throws -> [TradeConversation] {
        var conversation = detail.conversation
        conversation.unread = 2
        return [conversation]
    }
    func agents() async throws -> [TradeUser] { throw URLError(.timedOut) }
    func create(title: String, role: TradeRole, agentID: Int64) async throws -> Int64 { 42 }
    func room(id: Int64) async throws -> TradeRoom { detail }
    func messages(id: Int64, before: Int64?) async throws -> TradeMessagePage {
        .init(messages: [.init(id: 10, sender: .init(id: 2, username: "seller"), content: "hello", createdAt: "2026-11-23T12:34:56.123Z", type: "text")], hasMore: false)
    }
    func send(_ text: String, to id: Int64) async throws -> TradeMessage { try deliver(text, reply: nil) }
    func send(_ text: String, to id: Int64, replyingTo: Int64) async throws -> TradeMessage { try deliver(text, reply: replyingTo) }
    private func deliver(_ text: String, reply: Int64?) throws -> TradeMessage {
        sentReplies.append(reply)
        if failSend { throw URLError(.timedOut) }
        return .init(id: 11, sender: nil, content: text, createdAt: nil, type: "text")
    }
    func invitation(for tradeID: Int64) async throws -> URL { TradeAPIClient.webURL }
    func invitation(token: String) async throws -> TradeInvitation {
        .init(conversationId: 42, kind: "participant", trade: detail.trade!,
              roles: [.init(role: "buyer", allowed: true, takenBy: nil), .init(role: "seller", allowed: true, takenBy: "taken")], myRole: nil)
    }
    func join(token: String, role: String?) async throws -> Int64 { joinCalls += 1; throw URLError(.timedOut) }
    func perform(_ action: TradeAction, tradeID: Int64) async throws { actionCalls += 1; if failAction { throw URLError(.timedOut) } }
    func updateTerms(_ terms: TradeTerms, tradeID: Int64) async throws {}
    func markRead(conversationID: Int64, messageID: Int64) async throws { readCalls += 1; if failRead { throw URLError(.timedOut) } }
}


@MainActor
final class TradeLayoutTests: XCTestCase {
    func testTradeScreensRenderWithDarkModeAndAccessibilityType() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"{"conversation":{"id":42,"title":"A longer trade title for testing wrapping and navigation","status":"open"},"access":{"can_write":true,"role":"buyer"},"trade":{"id":8,"title":"A longer trade title for testing wrapping and navigation","stage":"in_progress","version":1,"price":"1234.50","agent_fee":"25.50","fee_payer":"split","progress_step":0,"steps":[{"key":"buyer_paid","label":"Buyer payment to intermediary","roles":["buyer"]},{"key":"agent_received","label":"Intermediary verifies payment","roles":["agent"]}]},"members":[{"id":1,"username":"A long participant display name","role":"buyer"},{"id":2,"username":"Seller","role":"seller"},{"id":3,"username":"Intermediary","role":"agent"}]}"#.utf8)
        let detail = try decoder.decode(TradeRoom.self, from: data)
        let api = InteractionStub(detail: detail)
        let home = TradeHomeModel(api: api)
        await home.load()
        let room = TradeRoomModel(id: 42, api: api)
        await room.reload()
        room.draft = "多行消息输入测试\nSecond line of the message"
        let views: [(String, AnyView)] = [
            ("home", AnyView(TradeHomeView(model: home))),
            ("room", AnyView(TradeRoomView(model: room))),
            ("details", AnyView(List { TradeDetailsView(room: detail) })),
            ("terms", AnyView(TradeTermsView(model: room, room: detail)))
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodeseek-trade-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, view) in views {
            for (variant, style, size) in [("light", UIUserInterfaceStyle.light, UIContentSizeCategory.large),
                                           ("dark-large", .dark, .accessibilityExtraExtraExtraLarge)] {
                let controller = UIHostingController(rootView: view.tradeTypography())
                controller.overrideUserInterfaceStyle = style
                let parent = UIViewController()
                parent.addChild(controller)
                parent.view.addSubview(controller.view)
                controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                controller.didMove(toParent: parent)
                parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: size), forChild: controller)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.rootViewController = parent
                window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 500_000_000)
                parent.view.layoutIfNeeded()
                XCTAssertFalse(controller.view.bounds.isEmpty)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.layer.render(in: UIGraphicsGetCurrentContext()!)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "trade-\(name)-\(variant)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try image.pngData()?.write(to: directory.appendingPathComponent("\(name)-\(variant).png"))
                window.isHidden = true
            }
        }
        print("Trade layout screenshots: \(directory.path)")
    }
}
