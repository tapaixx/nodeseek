import XCTest
import SwiftUI
@testable import nodeseek

@MainActor
final class ChatAssistantTests: XCTestCase {
    func testPostAssistantActionsLayoutWithSavedAPI() async throws {
        let configuration = try XCTUnwrap(ChatAssistantAPIConfiguration(address: "https://example.com/v1", model: "test-model", key: ""))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("post-assistant-actions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, style, size) in [("light", UIUserInterfaceStyle.light, UIContentSizeCategory.large),
                                    ("dark-large", .dark, .accessibilityExtraExtraExtraLarge)] {
            let view = ChatAssistantView(messages: [.init(speaker: "post", text: "虚构测试帖子")], canDraft: true,
                                         isPost: true, configuration: configuration) { _ in
                XCTFail("Rendering must not apply a reply")
                return false
            }
            let controller = UIHostingController(rootView: view)
            controller.overrideUserInterfaceStyle = style
            let parent = UIViewController()
            parent.addChild(controller)
            parent.view.addSubview(controller.view)
            controller.didMove(toParent: parent)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = parent
            controller.view.frame = window.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: size), forChild: controller)
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousWindow?.makeKey() }
            try await Task.sleep(nanoseconds: 650_000_000)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in window.layer.render(in: context.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "post-assistant-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    func testPostContextKeepsMainTextAndExcludesHiddenHTML() {
        let header = PostDetailHeaderContent(postID: "1", title: "主题", authorName: "示例", avatarURL: nil, metadataText: nil,
                                            contentHTML: "<p>正文 &amp; 说明</p><script>internalScript</script><p hidden>hidden text</p>")
        let messages = PostAssistantContext.messages(header: header, comments: [])
        XCTAssertEqual(messages.first?.speaker, "post")
        XCTAssertEqual(messages.first?.text, "主题\n\n正文 & 说明")
    }
    func testAPIConfigurationNormalizesAddressesAndRejectsUnsafeURLs() throws {
        for address in ["https://example.com", "https://example.com/v1/", "https://example.com/v1/chat/completions"] {
            XCTAssertEqual(ChatAssistantAPIConfiguration(address: address, model: "chat-model", key: "")?.endpoint.absoluteString,
                           "https://example.com/v1/chat/completions")
        }
        for address in ["http://example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=value", "https://example.com/#fragment"] {
            XCTAssertNil(ChatAssistantAPIConfiguration(address: address, model: "chat-model", key: ""))
        }
    }

    func testCustomAPIUsesConfiguredModelAndSeparatesInstructionsFromChat() async throws {
        let configuration = try XCTUnwrap(ChatAssistantAPIConfiguration(address: "https://example.com/gateway/v1", model: "chat-model", key: "test-only"))
        let output = try await ChatAssistantAPI().generate(configuration: configuration, instructions: "Summarize", conversation: "sample chat") { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "chat-model")
            XCTAssertEqual(payload["messages"] as? [[String: String]], [
                ["role": "system", "content": "Summarize"], ["role": "user", "content": "sample chat"]
            ])
            let response = try XCTUnwrap(HTTPURLResponse(url: configuration.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"choices":[{"message":{"role":"assistant","content":"summary"}}]}"#.utf8), response)
        }
        XCTAssertEqual(output, "summary")
    }
    func testContextKeepsRecentTextInOrderAndBoundsLongThreads() {
        let thread = (1...25).map { ChatAssistantMessage(speaker: "peer", text: "Message \($0)") }
        let context = ChatAssistantMessage.context(thread + [.init(speaker: "me", text: "\n ")])
        XCTAssertEqual(context.count, 20)
        XCTAssertEqual(context.first?.text, "Message 6")
        XCTAssertEqual(context.last?.text, "Message 25")

        let long = Array(repeating: ChatAssistantMessage(speaker: "me", text: String(repeating: "字", count: 1000)), count: 10)
        let clipped = ChatAssistantMessage.context(long)
        XCTAssertEqual(clipped.reduce(0) { $0 + $1.text.count }, 2800)
        XCTAssertTrue(clipped.allSatisfy { $0.text.count <= 600 })
    }

    func testApplyingSuggestionPreservesExistingDraft() {
        XCTAssertEqual(ChatAssistantContext.appending("建议", to: "已有草稿"), "已有草稿\n\n建议")
        XCTAssertEqual(ChatAssistantContext.appending("建议", to: " \n"), "建议")
    }

    func testSSEDeltaExtractionAndPayloadParsing() {
        let payload = """
        : keep-alive

        data: {"choices":[{"delta":{"content":"你好"}}]}

        data: {"choices":[{"delta":{"content":"，NodeSeek"}}]}

        data: [DONE]
        """
        XCTAssertEqual(ChatAssistantAPI.parseSSEPayload(payload), "你好，NodeSeek")
        XCTAssertEqual(ChatAssistantAPI.extractSSEDelta(from: "data: [DONE]"), "[DONE]")
        XCTAssertNil(ChatAssistantAPI.extractSSEDelta(from: "event: ping"))
    }

    func testCrossPostPromptBuilderIncludesPreviousAndCurrentPosts() {
        let postA = AssistantContextSnapshot(
            id: "post-101",
            kind: .post,
            postID: "101",
            title: "美西 CN2 GIA 测评",
            subtitle: "@alice",
            messages: [.init(speaker: "post", text: "年付 49 美元，三网回程 CN2 GIA")],
            capturedAt: Date()
        )
        let postB = AssistantContextSnapshot(
            id: "post-202",
            kind: .post,
            postID: "202",
            title: "日本软银 2C4G 出售",
            subtitle: "@bob",
            messages: [.init(speaker: "post", text: "年付 35 美元，晚高峰偶尔抖动")],
            capturedAt: Date()
        )
        let session = AssistantSession(
            turns: [
                AssistantChatTurn(role: .user, content: "帮我记住第一个机器"),
                AssistantChatTurn(role: .assistant, content: "好的，已记住美西 CN2 GIA。")
            ],
            referencedContexts: [postA]
        )

        let built = AssistantPromptBuilder.buildMessages(
            session: session,
            activeContext: postB,
            userPrompt: "这两个哪个更值？"
        )
        XCTAssertEqual(built.first?.role, "system")
        let systemPrompt = built.first?.content ?? ""
        XCTAssertTrue(systemPrompt.contains("美西 CN2 GIA 测评"))
        XCTAssertTrue(systemPrompt.contains("日本软银 2C4G 出售"))
        XCTAssertTrue(systemPrompt.contains("[CURRENTLY VIEWING]"))
        XCTAssertEqual(built.count, 4) // system + 2 history turns + new user turn
        XCTAssertTrue(built.last?.content.contains("这两个哪个更值？") == true)
    }

    func testSessionStorePersistsCrossPostConversationAcrossRestarts() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-store-test-\(UUID().uuidString)", isDirectory: true)
        let storageURL = tempDir.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let defaultsSuite = "assistant-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = FloatingAssistantSettings(userDefaults: defaults)
        XCTAssertTrue(settings.isFloatingOrbEnabled)

        let config = try XCTUnwrap(ChatAssistantAPIConfiguration(address: "https://example.com/v1", model: "gpt-test", key: "k"))
        let store = AssistantSessionStore(storageURL: storageURL, settings: settings, configuration: config)

        store.updateCurrentPostContext(
            postID: "1",
            title: "帖子 A",
            authorName: "authorA",
            commentCount: 2,
            messages: [.init(speaker: "post", text: "帖子 A 正文")],
            draftHandler: nil
        )

        let mockTransport: (URLRequest) async throws -> (Data, URLResponse) = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: config.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"choices":[{"message":{"role":"assistant","content":"已收到并分析"}}]}"#.utf8), response)
        }

        store.sendMessage("总结帖子 A", transport: mockTransport)
        while store.isGenerating {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // 切换到帖子 B 并继续在同一会话中提问
        store.updateCurrentPostContext(
            postID: "2",
            title: "帖子 B",
            authorName: "authorB",
            commentCount: 5,
            messages: [.init(speaker: "post", text: "帖子 B 正文")],
            draftHandler: nil
        )
        store.sendMessage("对比帖子 A 和帖子 B", transport: mockTransport)
        while store.isGenerating {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(store.activeSession.turns.count, 4)
        XCTAssertEqual(store.activeSession.referencedContexts.map(\.postID), ["1", "2"])

        // 模拟重启 App，重新从磁盘加载
        let reloaded = AssistantSessionStore(storageURL: storageURL, settings: settings, configuration: config)
        XCTAssertEqual(reloaded.activeSession.turns.count, 4)
        XCTAssertEqual(reloaded.activeSession.referencedContexts.map(\.postID), ["1", "2"])
    }

    func testCancelledGenerationDoesNotClearReplacementRequestState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try XCTUnwrap(ChatAssistantAPIConfiguration(address: "https://example.com/v1", model: "test", key: ""))
        let store = AssistantSessionStore(storageURL: directory.appendingPathComponent("sessions.json"), configuration: configuration)
        let started = expectation(description: "first transport started")
        let response = try XCTUnwrap(HTTPURLResponse(url: configuration.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
        let payload = Data(#"{"choices":[{"message":{"role":"assistant","content":"replacement reply"}}]}"#.utf8)
        store.sendMessage("first") { _ in
            started.fulfill()
            // 模拟不及时响应取消的网络传输。
            try? await Task.sleep(nanoseconds: 250_000_000)
            return (payload, response)
        }
        await fulfillment(of: [started], timeout: 2)
        store.cancelGeneration()
        store.sendMessage("second") { _ in
            try await Task.sleep(nanoseconds: 800_000_000)
            return (payload, response)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(store.isGenerating, "旧任务结束不能清除新请求的生成状态")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.activeSession.turns.last?.content, "replacement reply")
        XCTAssertFalse(store.activeSession.turns.contains { $0.role == .assistant && $0.content.isEmpty })
    }

}
