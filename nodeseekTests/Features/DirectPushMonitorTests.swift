import XCTest
@testable import nodeseek

@MainActor
final class DirectPushMonitorTests: XCTestCase {
    func testBaselineNewIncomingMessagesDedupAndNoMarkRead() async throws {
        let (monitor, client, sender, _, _) = await fixture()
        client.messages = [message(id: 1)]
        await monitor.check()
        var delivered = await sender.events
        XCTAssertTrue(delivered.isEmpty)
        client.messages = [message(id: 2), message(id: 1), message(id: 3, receiver: 20)]
        await monitor.check()
        await monitor.check()
        delivered = await sender.events
        XCTAssertEqual(delivered.map(\.id), ["dm-10-2"])
        XCTAssertFalse(delivered[0].body.contains("private-body"))
        XCTAssertEqual(client.markCalls, 0)
    }

    func testAccountSwitchAndDisabledChannelDoNotForward() async {
        let (monitor, client, sender, store, accounts) = await fixture()
        await monitor.check()
        client.messages = [message(id: 2)]
        await accounts.save(AccountResponse(displayName: "Other", isLoggedIn: true, avatarURL: nil, profileURL: URL(string: "https://www.nodeseek.com/space/20"), stats: []))
        await monitor.check()
        store.values[.bark]?.enabled = false
        await monitor.check()
        let delivered = await sender.events
        XCTAssertTrue(delivered.isEmpty)
    }

    func testUncertainDeliveryIsNotAutomaticallyRetried() async {
        let (monitor, client, sender, _, _) = await fixture()
        await monitor.check()
        await sender.setFailure(.uncertain)
        client.messages = [message(id: 2)]
        await monitor.check()
        await monitor.check()
        let delivered = await sender.events
        XCTAssertEqual(delivered.count, 1)
    }

    func testBurstBeyondBudgetContinuesOnNextCheck() async {
        let (monitor, client, sender, _, _) = await fixture()
        await monitor.check()
        client.messages = (1...7).map { message(id: $0) }
        await monitor.check()
        XCTAssertEqual(sender.events.count, 5)
        await monitor.check()
        XCTAssertEqual(sender.events.count, 7)
    }

    private func message(id: Int, receiver: Int = 10) -> NodeSeekMessageConversationRecord {
        NodeSeekMessageConversationRecord(receiverID: receiver, senderID: 20, maxID: id, content: "private-body", createdAt: Date(), viewed: 0, senderName: "Alice", receiverName: "Me")
    }
    private func fixture() async -> (DirectPushMonitor, DirectPushClientStub, RecordingDirectPushSender, MemoryDirectPushStore, CurrentAccountStore) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let accounts = CurrentAccountStore(userDefaults: defaults)
        await accounts.save(AccountResponse(displayName: "Me", isLoggedIn: true, avatarURL: nil, profileURL: URL(string: "https://www.nodeseek.com/space/10"), stats: []))
        let store = MemoryDirectPushStore()
        store.values[.bark] = DirectPushConfiguration(channel: .bark, address: "https://api.day.app/fake-key", enabled: true, accountID: 10)
        let client = DirectPushClientStub(), sender = RecordingDirectPushSender()
        let monitor = DirectPushMonitor(store: store, client: client, sender: sender, accounts: accounts, defaults: defaults)
        return (monitor, client, sender, store, accounts)
    }
}

@MainActor
private final class DirectPushClientStub: NodeSeekNotificationClientProtocol {
    var messages: [NodeSeekMessageConversationRecord] = []
    var markCalls = 0
    @MainActor func loadUnreadCount() async throws -> NodeSeekNotificationUnreadCount { .zero }
    @MainActor func loadAtMe() async throws -> [NodeSeekNotificationRecord] { [] }
    @MainActor func loadReplies() async throws -> [NodeSeekNotificationRecord] { [] }
    @MainActor func loadMessageConversations() async throws -> [NodeSeekMessageConversationRecord] { messages }
    @MainActor func markViewed(ids: [Int], tab: NodeSeekNotificationTab) async throws { markCalls += 1 }
    @MainActor func markAllViewed(tab: NodeSeekNotificationTab) async throws { markCalls += 1 }
}
