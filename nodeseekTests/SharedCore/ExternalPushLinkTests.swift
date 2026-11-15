import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import NodeSeekCore
#else
@testable import nodeseek
#endif

struct ExternalPushLinkTests {
    private func link(type: String, target: String? = nil) -> URL {
        var parts = URLComponents(string: "nsconnect://notification")!
        parts.queryItems = [URLQueryItem(name: "type", value: type)]
        if let target { parts.queryItems?.append(URLQueryItem(name: "url", value: target)) }
        return parts.url!
    }

    @Test func barkReplyOpensNativePost() throws {
        let route = try #require(ExternalPushLink.route(from: link(type: "reply", target: "https://www.nodeseek.com/post-123-2#13")))
        guard case let .reply(id, page, floor, _) = route else { Issue.record("Expected native post"); return }
        #expect(id == "123")
        #expect(page == 2)
        #expect(floor == "13")
    }

    @Test func barkMessageKeepsConversationAndFallback() throws {
        let target = "https://www.nodeseek.com/notification#/message?mode=talk&to=20"
        guard case let .webPage(url, _) = ExternalPushLink.route(from: link(type: "message", target: target)) else {
            Issue.record("Expected native profile router input"); return
        }
        #expect(url.absoluteString == target)
        #expect(ExternalPushLink.route(from: link(type: "message")) == .messageList)
        #expect(ExternalPushLink.route(from: link(type: "reply")) == .replyList)
        #expect(ExternalPushLink.route(from: link(type: "checkin")) == .checkin)
    }

    @Test(arguments: ["https://evil.test/post-123-1", "javascript:alert(1)", "http://www.nodeseek.com/post-1-1", "https://nodeseek.com.evil.test/post-1-1", "https://user:pass@www.nodeseek.com/notification", "https://www.nodeseek.com/login", "https://www.nodeseek.com/post-1-1/evil"])
    func rejectsExternalOrUnexpectedTarget(target: String) {
        #expect(ExternalPushLink.route(from: link(type: "reply", target: target)) == nil)
    }

    @Test(arguments: ["nsconnect://notification?type=message&type=reply", "nsconnect://notification?type=message&unknown=x", "nsconnect://notification/wrong?type=message", "https://notification?type=message", "nsconnect://notification?type=unsupported"])
    func rejectsMalformedLinks(raw: String) {
        #expect(ExternalPushLink.route(from: URL(string: raw)! ) == nil)
    }

}
