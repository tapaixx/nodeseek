import UIKit
import XCTest
@testable import nodeseek

@MainActor
final class MessageConversationTests: XCTestCase {
    func testLoadsConversationAndMarksOnlyIncomingUnreadMessages() async throws {
        let client = StubMessageClient()
        let model = try await makeModel(client: client)
        await model.load()
        await model.load()
        XCTAssertEqual(model.messages.map(\.id), [1, 2])
        XCTAssertEqual(model.participantName, "Alice")
        XCTAssertEqual(client.markedIDs, [[1]])
        XCTAssertTrue(model.hasLoaded)
    }

    func testFailedSendPreservesDraftAndServerMessage() async throws {
        let client = StubMessageClient()
        client.sendError = NodeSeekMessageError.rejected("发送过于频繁")
        let model = try await makeModel(client: client)
        await model.load()
        model.draft = "尚未发送的内容"
        await model.send()
        XCTAssertEqual(model.draft, "尚未发送的内容")
        XCTAssertEqual(model.errorMessage, "发送过于频繁")
        XCTAssertFalse(model.isSending)
    }

    func testSuccessfulSendClearsDraftEvenWhenRefreshFails() async throws {
        let client = StubMessageClient()
        let model = try await makeModel(client: client)
        await model.load()
        model.draft = "  你好  "
        client.loadError = URLError(.notConnectedToInternet)
        await model.send()
        XCTAssertEqual(client.sentContents, ["你好"])
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.errorMessage, "私信已发送，更新对话失败，请下拉刷新")
    }

    func testUncertainDeliveryRequiresAcknowledgementBeforeResending() async throws {
        let client = StubMessageClient()
        client.sendError = NodeSeekMessageError.deliveryUncertain
        let model = try await makeModel(client: client)
        await model.load()
        model.draft = "你好"
        await model.send()
        await model.send()
        XCTAssertEqual(client.sentContents.count, 1)
        XCTAssertEqual(model.draft, "你好")
        XCTAssertTrue(model.deliveryUncertain)
        model.acknowledgeUncertainDelivery()
        client.sendError = nil
        await model.send()
        XCTAssertEqual(client.sentContents.count, 2)
        XCTAssertEqual(model.draft, "")
    }

    func testRepeatedSendWhileWaitingSubmitsOnlyOnce() async throws {
        let client = StubMessageClient()
        client.suspendSend = true
        let model = try await makeModel(client: client)
        await model.load()
        model.draft = "你好"
        let first = Task { await model.send() }
        while client.pendingSend == nil { await Task.yield() }
        await model.send()
        XCTAssertEqual(client.sentContents.count, 1)
        client.pendingSend?.resume()
        await first.value
    }

    func testLogoutClearsPrivateContentAndPreventsSend() async throws {
        let client = StubMessageClient()
        let store = await makeStore()
        let model = MessageConversationViewModel(participantID: 20, client: client, currentAccountStore: store)
        await model.load()
        model.draft = "私人草稿"
        await store.clear()
        await model.send()
        XCTAssertTrue(client.sentContents.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertFalse(model.hasLoaded)
    }

    func testPushConversationURLUsesNativeController() {
        let url = NodeSeekMessageClient.webURL(participantID: 20)
        let controller = UserProfileRouter.makeViewController(profileURL: url)
        XCTAssertEqual((controller as? MessageConversationViewController)?.model.participantID, 20)
        let external = UserProfileRouter.makeViewController(profileURL: URL(string: "https://example.com/notification#/message?mode=talk&to=20")!)
        XCTAssertTrue(external is UserInfoWebViewController)
    }

    func testSendUsesWebsiteSessionAndExactPayload() async throws {
        var captured: [String: Any] = [:]
        let client = NodeSeekMessageClient(pageAction: { url, source, arguments in
            XCTAssertEqual(url, NodeSeekMessageClient.webURL(participantID: 20))
            XCTAssertTrue(source.contains("/api/notification/message/send"))
            captured = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((arguments["bodyJSON"] as! String).utf8)) as? [String: Any])
            return ["ok": true]
        })
        try await client.send(content: "引号\"与换行\n中文", participantID: 20)
        XCTAssertEqual(captured["receiverUid"] as? Int, 20)
        XCTAssertEqual(captured["markdown"] as? Bool, false)
        XCTAssertEqual(captured["content"] as? String, "引号\"与换行\n中文")
    }

    func testTransportFailureIsReportedAsUncertain() async throws {
        let client = NodeSeekMessageClient(pageAction: { _, _, _ in throw URLError(.timedOut) })
        do {
            try await client.send(content: "你好", participantID: 20)
            XCTFail("Expected uncertain delivery")
        } catch {
            XCTAssertEqual(error as? NodeSeekMessageError, .deliveryUncertain)
        }
    }

    func testReadRequestUsesConversationAPIAndPreparesCookies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var prepared = false
        MessageURLProtocol.responseBody = #"{"success":true,"talkTo":{"member_id":20,"member_name":"Alice"},"msgArray":[]}"#
        let client = NodeSeekMessageClient(session: session, cookiePreparer: { prepared = true })
        let thread = try await client.loadConversation(participantID: 20)
        XCTAssertTrue(prepared)
        XCTAssertEqual(thread.talkTo?.memberID, 20)
        XCTAssertEqual(MessageURLProtocol.lastRequest?.url?.path, "/api/notification/message/with/20")
        XCTAssertEqual(MessageURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer"), NodeSeekMessageClient.webURL(participantID: 20).absoluteString)
        XCTAssertEqual(MessageURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testReadRejectsMismatchedParticipant() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MessageURLProtocol.responseBody = #"{"success":true,"talkTo":{"member_id":30,"member_name":"Other"},"msgArray":[]}"#
        let client = NodeSeekMessageClient(session: session, cookiePreparer: {})
        do {
            _ = try await client.loadConversation(participantID: 20)
            XCTFail("Expected mismatched participant to be rejected")
        } catch {
            XCTAssertEqual(error as? NodeSeekMessageError, .invalidParticipant)
        }
    }

    func testConversationLayoutInLightAndDarkMode() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let client = StubMessageClient()
            let store = await makeStore()
            let controller = MessageConversationViewController(participantID: 20, participantName: "Alice", client: client, currentAccountStore: store, profileClient: StubMessageParticipantClient())
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UINavigationController(rootViewController: controller)
            window.makeKeyAndVisible()
            controller.loadViewIfNeeded()
            for _ in 0..<1_000 {
                if controller.model.hasLoaded { break }
                await Task.yield()
            }
            XCTAssertTrue(controller.model.hasLoaded)
            await controller.model.loadParticipant()
            controller.model.draft = "在应用内直接回复"
            controller.model.onChange?()
            window.layoutIfNeeded()
            let input = try XCTUnwrap(findView(in: controller.view, identifier: "message-conversation-input") as? UITextView)
            XCTAssertGreaterThan(input.frame.height, 40)
            XCTAssertGreaterThan(input.frame.width, window.bounds.width * 0.6)
            XCTAssertLessThanOrEqual(input.convert(input.bounds, to: window).maxY, window.bounds.maxY)
            let table = try XCTUnwrap(findView(in: controller.view, identifier: "message-conversation-table") as? UITableView)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
            for row in 0..<table.numberOfRows(inSection: 0) {
                let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: row, section: 0)))
                let timestamp = try XCTUnwrap(findView(in: cell.contentView, identifier: "message-timestamp") as? UILabel)
                XCTAssertFalse(timestamp.isHidden)
                XCTAssertNotNil(timestamp.text?.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
                XCTAssertTrue(timestamp.text?.hasSuffix(row == 0 ? ":00" : ":10") == true)
                let bubble = try XCTUnwrap(cell.contentView.subviews.first { $0 is UITextView })
                XCTAssertEqual(bubble.frame.minY - timestamp.frame.maxY, 8, accuracy: 0.5)
            }
            let profile = try XCTUnwrap(findView(in: controller.view, identifier: "message-participant-profile") as? UIControl)
            XCTAssertTrue(profile.accessibilityLabel?.contains("Lv.3") == true)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = style == .light ? "message-light-collapsed" : "message-dark-collapsed"
            attachment.lifetime = .keepAlways
            add(attachment)
            let toggle = try XCTUnwrap(findView(in: controller.view, identifier: "message-participant-toggle") as? UIButton)
            XCTAssertEqual(toggle.accessibilityValue, "已收起")
            UIView.performWithoutAnimation { toggle.sendActions(for: .touchUpInside); window.layoutIfNeeded() }
            XCTAssertEqual(toggle.accessibilityValue, "已展开")
            let expandedImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let expanded = XCTAttachment(image: expandedImage)
            expanded.name = style == .light ? "message-light-expanded" : "message-dark-expanded"
            expanded.lifetime = .keepAlways
            add(expanded)
            window.isHidden = true
        }
    }

    func testParticipantProfileAndLatestPostDoNotDependOnConversationLoading() async throws {
        let client = StubMessageClient()
        client.loadError = URLError(.notConnectedToInternet)
        let model = MessageConversationViewModel(participantID: 20, client: client, currentAccountStore: await makeStore(), profileClient: StubMessageParticipantClient())
        await model.loadParticipant()
        XCTAssertEqual(model.participantProfile?.uid, 20)
        XCTAssertEqual(model.participantProfile?.rank, 3)
        XCTAssertEqual(model.latestDiscussion?.postID, 123)
        XCTAssertFalse(model.hasLoaded)
    }

    func testParticipantCardAndAvatarOpenNativeProfile() async throws {
        let controller = MessageConversationViewController(participantID: 20, client: StubMessageClient(), currentAccountStore: await makeStore(), profileClient: StubMessageParticipantClient())
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let toggle = try XCTUnwrap(findView(in: controller.view, identifier: "message-participant-toggle") as? UIButton)
        toggle.sendActions(for: .touchUpInside)
        let profile = try XCTUnwrap(findView(in: controller.view, identifier: "message-participant-profile") as? UIControl)
        profile.sendActions(for: .touchUpInside)
        XCTAssertTrue(navigation.topViewController is UserProfileViewController)
    }

    func testBubbleWidthFollowsTextAndAvatarStaysOnItsSide() throws {
        func message(_ content: String) throws -> NodeSeekDirectMessage {
            let data = try JSONSerialization.data(withJSONObject: ["id": 1, "sender_id": 20, "receiver_id": 10, "content": content, "created_at": "2026-11-15T01:00:00Z"])
            return try JSONDecoder().decode(NodeSeekDirectMessage.self, from: data)
        }
        let cell = MessageBubbleCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 140)
        cell.configure(try message("你好"), isMine: false, availableWidth: 390, onProfile: { _ in })
        cell.layoutIfNeeded()
        let bubble = try XCTUnwrap(cell.contentView.subviews.first { $0 is UITextView })
        let avatar = try XCTUnwrap(findView(in: cell.contentView, identifier: "message-sender-avatar"))
        XCTAssertLessThan(bubble.frame.width, 120)
        XCTAssertLessThanOrEqual(avatar.frame.maxX, bubble.frame.minX)
        cell.configure(try message(String(repeating: "这是较长的私信内容", count: 12)), isMine: true, availableWidth: 390, onProfile: { _ in })
        cell.layoutIfNeeded()
        XCTAssertGreaterThan(bubble.frame.width, 200)
        XCTAssertLessThanOrEqual(bubble.frame.width, 390 * 0.72 + 1)
        XCTAssertLessThanOrEqual(bubble.frame.maxX, avatar.frame.minX)
    }

    func testEveryMessageShowsFullTimestampToSecondsAfterReuse() throws {
        let calendar = Calendar(identifier: .gregorian)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5)))
        let iso = ISO8601DateFormatter()
        let cell = MessageBubbleCell(style: .default, reuseIdentifier: nil)
        for (offset, expected) in [(0, "2025-01-02 03:04:05"), (1, "2025-01-02 03:04:06")] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": offset + 1, "sender_id": 20, "receiver_id": 10, "content": "连续消息",
                "created_at": iso.string(from: date.addingTimeInterval(Double(offset)))
            ])
            let message = try JSONDecoder().decode(NodeSeekDirectMessage.self, from: data)
            cell.configure(message, isMine: offset == 1, availableWidth: 390, onProfile: { _ in })
            let timestamp = try XCTUnwrap(findView(in: cell.contentView, identifier: "message-timestamp") as? UILabel)
            XCTAssertFalse(timestamp.isHidden)
            XCTAssertEqual(timestamp.text, expected)
            cell.prepareForReuse()
        }
    }

    private func findView(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.findView(in: $0, identifier: identifier) }.first
    }

    private func makeModel(client: StubMessageClient) async throws -> MessageConversationViewModel {
        MessageConversationViewModel(participantID: 20, client: client, currentAccountStore: await makeStore())
    }

    private func makeStore() async -> CurrentAccountStore {
        let store = CurrentAccountStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.save(AccountResponse(
            displayName: "我", isLoggedIn: true, avatarURL: nil,
            profileURL: URL(string: "https://www.nodeseek.com/space/10"), stats: []
        ))
        return store
    }
}

private final class MessageURLProtocol: URLProtocol, @unchecked Sendable {
    static var responseBody = ""
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class StubMessageClient: NodeSeekMessageClientProtocol {
    var markedIDs: [[Int]] = []
    var sentContents: [String] = []
    var sendError: Error?
    var loadError: Error?
    var suspendSend = false
    var pendingSend: CheckedContinuation<Void, Never>?

    func loadConversation(participantID: Int) async throws -> NodeSeekMessageThread {
        if let loadError { throw loadError }
        return try JSONDecoder().decode(NodeSeekMessageThread.self, from: Data("""
        {"success":true,"talkTo":{"member_id":20,"member_name":"Alice"},"msgArray":[
          {"id":1,"sender_id":20,"receiver_id":10,"content":"你好，私信可以直接在应用里查看吗？\\nhttps://www.nodeseek.com","created_at":"2026-11-15T01:00:00Z","viewed":0,"is_markdown":false},
          {"id":2,"sender_id":10,"receiver_id":20,"content":"可以，直接回复。","created_at":"2026-11-15T01:00:10Z","viewed":0,"is_markdown":true}
        ]}
        """.utf8))
    }

    func send(content: String, participantID: Int) async throws {
        sentContents.append(content)
        if suspendSend { await withCheckedContinuation { pendingSend = $0 } }
        if let sendError { throw sendError }
    }

    func markViewed(ids: [Int]) async throws { markedIDs.append(ids) }
}

@MainActor
private final class StubMessageParticipantClient: MessageParticipantLoading {
    func loadProfile(uid: Int) async throws -> UserProfileRecord {
        UserProfileRecord(uid: uid, name: "Alice", rank: 3, coin: 1200, stardust: 10, bio: "交流服务器与网络", readme: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000), postCount: 12, commentCount: 100, follows: 2, fans: 8, collectionCount: nil, roleNames: [])
    }
    func loadDiscussions(uid: Int, page: Int) async throws -> [UserDiscussionRecord] {
        [UserDiscussionRecord(rank: 0, title: "最近在用的几台 VPS，分享一些体验", postID: 123)]
    }
}
