import UIKit
import XCTest
@testable import nodeseek

@MainActor
final class AppMessageCenterTests: XCTestCase {
    func testAnyPagePollingBaselinesAndNotifiesSameCountNewMessageWithoutMarkingRead() async throws {
        let f = await fixture()
        f.client.messages = [message(1)]
        f.client.counts = .init(message: 1, atMe: 0, reply: 0, all: 1)
        var received: [InAppMessageEvent] = []
        f.center.onNewEvents = { received += $0 }
        await f.center.refresh()
        XCTAssertEqual(f.center.unreadCount.all, 1)
        XCTAssertTrue(received.isEmpty)
        f.client.messages = [message(2)]
        await f.center.refresh()
        await f.center.refresh()
        XCTAssertEqual(received.map(\.id), ["dm-10-2"])
        XCTAssertEqual(received.first?.participantID, 20)
        XCTAssertFalse(received.first?.body.contains("private-body") ?? true)
        XCTAssertEqual(f.client.markCalls, 0)
    }

    func testDisabledAlertsStillUpdateBadgeAndNeverSendBackgroundNotification() async {
        let f = await fixture(foreground: false)
        await f.center.refresh()
        f.center.alertsEnabled = false
        var posted = 0
        f.center.onLocalEvent = { _ in posted += 1 }
        f.client.messages = [message(2)]
        f.client.counts = .init(message: 1, atMe: 0, reply: 0, all: 1)
        await f.center.refresh()
        XCTAssertEqual(f.center.unreadCount.all, 1)
        XCTAssertEqual(posted, 0)
    }

    func testBackgroundRefreshUsesIndependentLocalDeliveryAndIgnoresOutgoingReadRows() async {
        let f = await fixture(foreground: false)
        await f.center.refresh()
        var received: [InAppMessageEvent] = []
        f.center.onLocalEvent = { received.append($0) }
        f.client.counts = .init(message: 3, atMe: 0, reply: 0, all: 3)
        f.client.messages = [message(2), message(3, receiver: 20), message(4, viewed: 1)]
        await f.center.refresh()
        await f.center.refresh()
        XCTAssertEqual(received.map(\.id), ["dm-10-2"])
    }

    func testLogoutAndAccountSwitchDoNotLeakOrAlertOldAccount() async {
        let f = await fixture()
        await f.center.refresh()
        var received = 0
        f.center.onNewEvents = { received += $0.count }
        f.client.messages = [message(2)]
        f.client.counts = .init(message: 1, atMe: 0, reply: 0, all: 1)
        await f.accounts.clear()
        await f.center.refresh()
        XCTAssertEqual(f.center.unreadCount, .zero)
        await saveAccount(30, to: f.accounts)
        await f.center.refresh()
        XCTAssertEqual(received, 0)
    }

    func testAccountSwitchWhileRequestIsPendingDiscardsOldResult() async {
        let f = await fixture()
        var continuation: CheckedContinuation<Void, Never>?
        f.client.beforeCount = { await withCheckedContinuation { continuation = $0 } }
        f.client.counts = .init(message: 7, atMe: 0, reply: 0, all: 7)
        let request = Task { await f.center.refresh() }
        while continuation == nil { await Task.yield() }
        await saveAccount(30, to: f.accounts)
        continuation?.resume()
        await request.value
        XCTAssertEqual(f.center.unreadCount, .zero)
    }

    func testCurrentConversationSuppressesBannerButOtherParticipantStillAlerts() async throws {
        let f = await fixture()
        let chat = MessageConversationViewController(participantID: 20, client: OfflineMessagePageClient(), currentAccountStore: f.accounts, profileClient: OfflineMessagePageClient())
        let nav = MessageNavigationController(rootViewController: chat, messageCenter: f.center)
        let window = try makeWindow(nav)
        defer { window.isHidden = true }
        f.center.attach(window: window)
        await f.center.refresh()
        var received: [InAppMessageEvent] = []
        f.center.onNewEvents = { received += $0 }
        f.client.counts = .init(message: 2, atMe: 0, reply: 0, all: 2)
        f.client.messages = [message(2), .init(receiverID: 10, senderID: 30, maxID: 3, content: "private-body", createdAt: Date(), viewed: 0, senderName: "Bob", receiverName: "Me")]
        await f.center.refresh()
        XCTAssertEqual(received.map(\.participantID), [30])
    }

    func testRemoteReceiptSuppressesDuplicateInAppAlert() async {
        let f = await fixture()
        await f.center.refresh()
        var received = 0
        f.center.onNewEvents = { received += $0.count }
        let row = message(2)
        f.client.messages = [row]
        f.client.counts = .init(message: 1, atMe: 0, reply: 0, all: 1)
        f.center.noteRemote(userInfo: ["type": "message", "url": row.conversationWebURL(currentUserID: 10).absoluteString])
        await f.center.refresh()
        XCTAssertEqual(received, 0)
    }

    func testSharedClientCoalescesReadsInvalidatesAndScopesCacheToAccount() async throws {
        let f = await fixture()
        let shared = SharedNotificationClient(base: f.client, accounts: f.accounts)
        async let first = shared.loadUnreadCount()
        async let second = shared.loadUnreadCount()
        _ = try await (first, second)
        _ = try await shared.loadUnreadCount()
        XCTAssertEqual(f.client.countCalls, 1)
        try await shared.markAllViewed(tab: .message)
        _ = try await shared.loadUnreadCount()
        XCTAssertEqual(f.client.countCalls, 2)
        await saveAccount(30, to: f.accounts)
        _ = try await shared.loadUnreadCount()
        XCTAssertEqual(f.client.countCalls, 3)
    }

    func testExistingNotificationEntriesSuppressShortcutAndRespectTabCustomization() {
        let home = PostListRouter.createModule(layout: .reading)
        XCTAssertTrue(MessageShortcutPolicy.hasExistingEntry(in: home))

        let settings = AppNavigationLayoutSettings(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let tabs = MainTabBarController(layoutSettings: settings)
        XCTAssertTrue(MessageShortcutPolicy.hasExistingEntry(in: tabs))
        tabs.select(.me)
        XCTAssertTrue(MessageShortcutPolicy.hasExistingEntry(in: tabs))
        tabs.applyTabItems([.home, .me])
        XCTAssertFalse(MessageShortcutPolicy.hasExistingEntry(in: tabs))
        tabs.select(.home)
        XCTAssertFalse(MessageShortcutPolicy.hasExistingEntry(in: tabs))
        XCTAssertFalse(MessageShortcutPolicy.hasExistingEntry(in: UIViewController()))
    }

    func testNotificationPageRemovesShortcutAndPreservesOriginalActions() async throws {
        let f = await fixture()
        let editor = UIViewController()
        let nav = MessageNavigationController(rootViewController: editor, messageCenter: f.center)
        let window = try makeWindow(nav)
        defer { window.isHidden = true }
        _ = try shortcut(in: nav)
        let inbox = NotificationViewController(client: f.client, currentAccountStore: f.accounts, isLoggedIn: { false })
        inbox.loadViewIfNeeded()
        let originalButtons = inbox.navigationItem.rightBarButtonItems ?? []
        let staleShortcut = UIBarButtonItem(customView: MessageShortcutButton(frame: .zero))
        staleShortcut.accessibilityIdentifier = MessageNavigationBar.shortcutID
        inbox.navigationItem.rightBarButtonItems = originalButtons + [staleShortcut]
        nav.pushViewController(inbox, animated: false)
        (nav.navigationBar as? MessageNavigationBar)?.updateShortcut()
        XCTAssertEqual(inbox.navigationItem.rightBarButtonItems, originalButtons)
        nav.popViewController(animated: false)
        _ = try shortcut(in: nav)
    }

    func testReadingHomeSuppressesFloatingShortcut() async throws {
        let f = await fixture()
        let nav = MessageNavigationController(rootViewController: PostListRouter.createModule(layout: .reading), messageCenter: f.center)
        let window = try makeWindow(nav)
        defer { window.isHidden = true }
        f.center.attach(window: window)
        nav.setNavigationBarHidden(true, animated: false)
        f.center.updatePresentation()
        XCTAssertFalse(window.subviews.contains { $0 is MessageShortcutButton })
    }

    func testShortcutPreservesSaveButtonAndDraftAcrossPagesAndAsyncButtonChanges() async throws {
        let f = await fixture()
        f.center.makeInbox = { NotificationViewController(initialTab: $0, client: f.client, currentAccountStore: f.accounts, isLoggedIn: { true }) }
        let editor = UIViewController()
        let draft = UITextView(); draft.text = "未发送的帖子草稿"; editor.view.addSubview(draft)
        let save = UIBarButtonItem(title: "保存", style: .done, target: nil, action: nil)
        editor.navigationItem.rightBarButtonItem = save
        let nav = MessageNavigationController(rootViewController: editor, messageCenter: f.center)
        let window = try makeWindow(nav)
        defer { window.isHidden = true }
        f.center.attach(window: window)
        nav.navigationBar.layoutIfNeeded()
        XCTAssertTrue(editor.navigationItem.rightBarButtonItem === save)
        let first = try shortcut(in: nav)
        XCTAssertEqual(first.accessibilityValue, "0")
        editor.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "发布", style: .done, target: nil, action: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(editor.navigationItem.rightBarButtonItems?.filter { $0.accessibilityIdentifier == MessageNavigationBar.shortcutID }.count, 1)
        XCTAssertEqual(editor.navigationItem.rightBarButtonItem?.title, "发布")
        UIView.performWithoutAnimation { first.sendActions(for: .touchUpInside) }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(nav.topViewController is NotificationViewController)
        XCTAssertEqual(nav.viewControllers.count, 2)
        f.center.openMessages(in: nav)
        XCTAssertEqual(nav.viewControllers.count, 2)
        nav.popViewController(animated: false)
        XCTAssertTrue(nav.topViewController === editor)
        XCTAssertEqual(draft.text, "未发送的帖子草稿")
    }

    func testModalShortcutOpensInsideCurrentModalAndFullScreenFallbackPreservesPage() async throws {
        let f = await fixture()
        f.center.makeInbox = { NotificationViewController(initialTab: $0, client: f.client, currentAccountStore: f.accounts, isLoggedIn: { true }) }
        let root = MessageNavigationController(rootViewController: UIViewController(), messageCenter: f.center)
        let window = try makeWindow(root)
        defer { window.isHidden = true }
        f.center.attach(window: window)
        let editor = UIViewController()
        let modal = MessageNavigationController(rootViewController: editor, messageCenter: f.center)
        root.present(modal, animated: false)
        modal.view.layoutIfNeeded()
        try shortcut(in: modal).sendActions(for: .touchUpInside)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(modal.viewControllers.count, 2)
        XCTAssertEqual(root.viewControllers.count, 1)
        modal.dismiss(animated: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        let fullScreen = UIViewController(); fullScreen.modalPresentationStyle = .fullScreen
        root.present(fullScreen, animated: false)
        XCTAssertTrue(root.presentedViewController === fullScreen)
        f.center.updatePresentation()
        let fallback = try XCTUnwrap(window.subviews.compactMap { $0 as? MessageShortcutButton }.first)
        fallback.sendActions(for: .touchUpInside)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(fullScreen.presentedViewController is MessageNavigationController)
        XCTAssertTrue(root.presentedViewController === fullScreen)
    }

    func testNotificationRoutingUsesCurrentModalAndAlertsSwitchPersistsChoice() async throws {
        let f = await fixture()
        let root = MessageNavigationController(rootViewController: UIViewController(), messageCenter: f.center)
        let window = try makeWindow(root)
        defer { window.isHidden = true }
        f.center.attach(window: window)
        let settings = PushNotificationSettingsViewController(messageCenter: f.center, authorizationStatusProvider: { .authorized })
        let modal = MessageNavigationController(rootViewController: settings, messageCenter: f.center)
        root.present(modal, animated: false)
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        let toggle = try XCTUnwrap(cell.accessoryView as? UISwitch)
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        XCTAssertFalse(f.center.alertsEnabled)
        let detail = UIViewController()
        XCTAssertTrue(f.center.show(detail))
        XCTAssertTrue(modal.topViewController === detail)
        XCTAssertEqual(root.viewControllers.count, 1)
    }

    func testShortcutAndBannerLayoutInLightAndDark() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let f = await fixture()
            let settings = PushNotificationSettingsViewController(messageCenter: f.center, authorizationStatusProvider: { .authorized })
            let nav = MessageNavigationController(rootViewController: settings, messageCenter: f.center)
            let window = try makeWindow(nav); window.overrideUserInterfaceStyle = style
            defer { window.isHidden = true }
            f.center.attach(window: window)
            f.client.counts = .init(message: 128, atMe: 2, reply: 1, all: 131)
            await f.center.refresh()
            window.layoutIfNeeded()
            let button = try shortcut(in: nav)
            XCTAssertEqual(button.accessibilityValue, "131")
            let badge = try XCTUnwrap(button.subviews.compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "message-unread-badge" })
            XCTAssertFalse(badge.isHidden)
            XCTAssertNotNil(badge.image)
            XCTAssertEqual(button.bounds.width, 44, accuracy: 1)
            let frame = button.convert(button.bounds, to: window)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
            XCTAssertGreaterThan(frame.minX, window.bounds.width * 0.65)
            attach(window, name: "global-messages-\(style == .light ? "light" : "dark")")
            f.client.messages = [message(2)]
            await f.center.refresh()
            try await Task.sleep(nanoseconds: 250_000_000)
            window.layoutIfNeeded()
            let banner = try XCTUnwrap(window.subviews.first { $0 is MessageBannerView })
            XCTAssertGreaterThanOrEqual(banner.frame.minY, window.safeAreaInsets.top)
            XCTAssertLessThan(banner.frame.width, window.bounds.width)
            attach(window, name: "global-banner-\(style == .light ? "light" : "dark")")
        }
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)

    }
    private func shortcut(in nav: UINavigationController) throws -> MessageShortcutButton {
        nav.navigationBar.setNeedsLayout(); nav.navigationBar.layoutIfNeeded()
        return try XCTUnwrap(nav.navigationBar.topItem?.rightBarButtonItems?.first { $0.accessibilityIdentifier == MessageNavigationBar.shortcutID }?.customView as? MessageShortcutButton)
    }
    private func makeWindow(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
        return window
    }
    private func message(_ id: Int, receiver: Int = 10, viewed: Int = 0) -> NodeSeekMessageConversationRecord {
        .init(receiverID: receiver, senderID: 20, maxID: id, content: "private-body", createdAt: Date(), viewed: viewed, senderName: "Alice", receiverName: "Me")
    }
    private func saveAccount(_ uid: Int, to accounts: CurrentAccountStore) async {
        await accounts.save(AccountResponse(displayName: "Me", isLoggedIn: true, avatarURL: nil, profileURL: URL(string: "https://www.nodeseek.com/space/\(uid)"), stats: []))
    }
    private func fixture(foreground: Bool = true) async -> (center: AppMessageCenter, client: AppMessageClientStub, accounts: CurrentAccountStore) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let accounts = CurrentAccountStore(userDefaults: defaults)
        await saveAccount(10, to: accounts)
        let client = AppMessageClientStub()
        let center = AppMessageCenter(client: client, verification: SiteVerificationCoordinator(), accounts: accounts, defaults: defaults, isForeground: { foreground })
        return (center, client, accounts)
    }
}

@MainActor
private final class AppMessageClientStub: NodeSeekNotificationClientProtocol {
    var counts = NodeSeekNotificationUnreadCount.zero
    var messages: [NodeSeekMessageConversationRecord] = []
    var beforeCount: (() async -> Void)?
    var countCalls = 0
    var markCalls = 0
    @MainActor func loadUnreadCount() async throws -> NodeSeekNotificationUnreadCount { countCalls += 1; await beforeCount?(); await Task.yield(); return counts }
    @MainActor func loadAtMe() async throws -> [NodeSeekNotificationRecord] { [] }
    @MainActor func loadReplies() async throws -> [NodeSeekNotificationRecord] { [] }
    @MainActor func loadMessageConversations() async throws -> [NodeSeekMessageConversationRecord] { messages }
    @MainActor func markViewed(ids: [Int], tab: NodeSeekNotificationTab) async throws { markCalls += 1 }
    @MainActor func markAllViewed(tab: NodeSeekNotificationTab) async throws { markCalls += 1 }
}

@MainActor
private final class OfflineMessagePageClient: NodeSeekMessageClientProtocol, MessageParticipantLoading {
    func loadConversation(participantID: Int) async throws -> NodeSeekMessageThread { throw URLError(.notConnectedToInternet) }
    func send(content: String, participantID: Int) async throws { XCTFail("Must not send") }
    func markViewed(ids: [Int]) async throws { XCTFail("Must not mark") }
    func loadProfile(uid: Int) async throws -> UserProfileRecord { throw URLError(.notConnectedToInternet) }
    func loadDiscussions(uid: Int, page: Int) async throws -> [UserDiscussionRecord] { [] }
}
