import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import NodeSeekCore
#else
@testable import nodeseek
#endif

struct InAppMessageLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ id: String, offset: TimeInterval = 0) -> InAppMessageEvent {
        InAppMessageEvent(id: id, accountID: 10, category: "message", title: "新私信", body: "点击查看",
                          date: now.addingTimeInterval(offset), url: nil, participantID: 20)
    }
    @Test func baselineDoesNotAlertAndSameCountNewIDStillAlerts() {
        var ledger = InAppMessageLedger()
        #expect(ledger.ingest([event("old")], category: "dm", now: now).isEmpty)
        #expect(ledger.ingest([event("new")], category: "dm", now: now).map(\.id) == ["new"])
        #expect(ledger.ingest([event("new")], category: "dm", now: now).isEmpty)
    }
    @Test func emptyBaselineAcceptsNewMessagesButNotOldHistory() {
        var ledger = InAppMessageLedger()
        #expect(ledger.ingest([], category: "dm", now: now).isEmpty)
        #expect(ledger.ingest([event("old", offset: -3_600), event("new")], category: "dm", now: now).map(\.id) == ["new"])
    }
    @Test func persistenceKeepsDedupWithoutMessageBodies() throws {
        var ledger = InAppMessageLedger()
        _ = ledger.ingest([event("first")], category: "dm", now: now)
        _ = ledger.ingest([event("second")], category: "dm", now: now)
        let data = try JSONEncoder().encode(ledger)
        #expect(!String(decoding: data, as: UTF8.self).contains("点击查看"))
        var restored = try JSONDecoder().decode(InAppMessageLedger.self, from: data)
        #expect(restored.ingest([event("first"), event("second")], category: "dm", now: now).isEmpty)
    }
    @Test func categoriesInitializeIndependentlyAndEventsRouteNatively() {
        var ledger = InAppMessageLedger()
        _ = ledger.ingest([], category: "dm", now: now)
        #expect(ledger.ingest([event("mention")], category: "at", now: now).isEmpty)
        var dm = event("dm")
        dm.url = URL(string: "https://www.nodeseek.com/notification#/message?mode=talk&to=20")!
        #expect(dm.route == .webPage(url: dm.url!, title: "私信"))
        var reply = event("reply")
        reply.category = "reply"
        reply.url = URL(string: "https://www.nodeseek.com/post-123-2#13")!
        #expect(reply.route == .reply(postID: "123", page: 2, floor: "13", url: reply.url!))
    }
}
