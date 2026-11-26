import XCTest
@testable import nodeseek

@MainActor
final class ChatAssistantTests: XCTestCase {
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
