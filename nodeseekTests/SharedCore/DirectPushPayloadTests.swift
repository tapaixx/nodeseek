import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import NodeSeekCore
#else
@testable import nodeseek
#endif

struct DirectPushPayloadTests {
    private var event: DirectPushEvent { DirectPushEvent(id: "dm-10-123", title: "测试私信", body: String(repeating: "🙂<内容>", count: 1000), type: "message", url: URL(string: "https://www.nodeseek.com/notification#/message?mode=talk&to=20"), date: Date()) }
    @Test func wecomUsesDirectWebhookAndByteBudget() throws {
        let config = DirectPushConfiguration(channel: .wecom, address: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=fake-key")
        let request = try DirectPushPayload.request(configuration: config, event: event)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let markdown = try #require(body["markdown"] as? [String: String])
        #expect(markdown["content"]!.utf8.count <= 4096)
        #expect(request.url?.host == "qyapi.weixin.qq.com")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }
    @Test func barkSplitsKeyFromCustomPrefixAndAddsBasicAuth() throws {
        let config = DirectPushConfiguration(channel: .bark, address: "https://bark.example.com/prefix/fake-key", username: "owner", password: "fake-pass")
        let request = try DirectPushPayload.request(configuration: config, event: event)
        #expect(request.url?.absoluteString == "https://bark.example.com/prefix/push")
        #expect(!request.url!.absoluteString.contains("fake-key"))
        #expect(request.httpBody!.count <= 3500)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["device_key"] as? String == "fake-key")
        #expect(body["level"] as? String == "active")
        #expect((body["url"] as? String)?.hasPrefix("nsconnect://notification?") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }
    @Test func httpSuccessMustAlsoHavePlatformSuccessCode() throws {
        try DirectPushPayload.check(data: Data(#"{"errcode":0}"#.utf8), status: 200, channel: .wecom)
        try DirectPushPayload.check(data: Data(#"{"code":200}"#.utf8), status: 200, channel: .bark)
        #expect(throws: DirectPushError.self) { try DirectPushPayload.check(data: Data(#"{"errcode":93000}"#.utf8), status: 200, channel: .wecom) }
        #expect(throws: DirectPushError.self) { try DirectPushPayload.check(data: Data(#"{"code":true}"#.utf8), status: 200, channel: .bark) }
    }
    @Test(arguments: ["http://api.day.app/key", "https://name:pass@api.day.app/key", "https://api.day.app/", "https://api.day.app/key?url=x"])
    func rejectsInvalidBarkAddress(raw: String) {
        #expect(throws: DirectPushError.self) { _ = try DirectPushConfiguration(channel: .bark, address: raw).validatedURL() }
    }
}
