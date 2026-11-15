import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import NodeSeekCore
#else
@testable import nodeseek
#endif

struct NodeSeekDirectMessageTests {
    @Test func decodesFlagsAndNormalizesConversationOrder() throws {
        let thread = try JSONDecoder().decode(NodeSeekMessageThread.self, from: Data("""
        {"success":true,"talkTo":{"member_id":20,"member_name":"Alice"},"msgArray":[
          {"id":2,"sender_id":10,"receiver_id":20,"content":"回复","created_at":"2026-11-15T01:00:01.000Z","viewed":1,"is_markdown":false},
          {"id":1,"sender_id":20,"receiver_id":10,"content":"你好","created_at":"2026-11-15T01:00:00Z","viewed":false,"is_markdown":1},
          {"id":2,"sender_id":10,"receiver_id":20,"content":"回复","created_at":"2026-11-15T01:00:01Z"},
          {"id":3,"sender_id":30,"receiver_id":10,"content":"其他会话","created_at":"2026-11-15T01:00:02Z"}
        ]}
        """.utf8))
        let messages = thread.messages(participantID: 20, currentUserID: 10)
        #expect(messages.map(\.id) == [1, 2])
        #expect(messages[0].isMarkdown)
        #expect(!messages[0].viewed)
        #expect(messages[1].viewed)
        #expect(!messages[1].isMarkdown)
    }

    @Test func decodesBusinessFailureWithoutMessageArray() throws {
        let response = try JSONDecoder().decode(NodeSeekMessageThread.self, from: Data(#"{"success":false,"message":"请先登录"}"#.utf8))
        #expect(!response.success)
        #expect(response.message == "请先登录")
        #expect(response.msgArray.isEmpty)
    }

    @Test func parsesConversationLinksRegardlessOfQueryOrder() throws {
        let url = try #require(URL(string: "https://www.nodeseek.com/notification#/message?to=20&mode=talk"))
        #expect(NodeSeekMessageRoute(url: url)?.participantID == 20)
    }

    @Test(arguments: [
        "https://example.com/notification#/message?mode=talk&to=20",
        "https://www.nodeseek.com/space/20#/message?mode=talk&to=20",
        "https://www.nodeseek.com/notification#/message?mode=list&to=20",
        "https://www.nodeseek.com/notification#/message?mode=talk&to=-1",
        "https://www.nodeseek.com/notification#/message?mode=talk&to=abc",
        "https://www.nodeseek.com/notification#/message?mode=talk",
        "file:///notification#/message?mode=talk&to=20"
    ]) func rejectsInvalidConversationLinks(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(NodeSeekMessageRoute(url: url) == nil)
    }
}
