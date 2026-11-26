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
}
