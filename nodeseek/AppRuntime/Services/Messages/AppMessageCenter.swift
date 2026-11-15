import UIKit
import UserNotifications
import SafariServices

@MainActor
final class AppMessageCenter {
    static let shared = AppMessageCenter()
    static let didChange = Notification.Name("AppMessageCenter.didChange")
    static let didReceive = Notification.Name("AppMessageCenter.didReceive")
    private(set) var unreadCount = NodeSeekNotificationUnreadCount.zero
    private let verification: SiteVerificationCoordinator
    private let client: NodeSeekNotificationClientProtocol
    private let accounts: CurrentAccountStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let isForeground: @MainActor () -> Bool
    private var loop: Task<Void, Never>?
    private var checking = false
    private var refreshPending = false
    private var epoch = 0
    private var accountID: Int?
    private var ledger = InAppMessageLedger()
    private var remoteReceipts: [String: Date] = [:]
    private weak var window: UIWindow?
    private weak var floatingShortcut: MessageShortcutButton?
    private weak var banner: MessageBannerView?
    var onNewEvents: (([InAppMessageEvent]) -> Void)?
    var onLocalEvent: ((InAppMessageEvent) async -> Void)?
    var makeInbox: (NodeSeekNotificationTab) -> NotificationViewController = { NotificationViewController(initialTab: $0) }

    init(client: NodeSeekNotificationClientProtocol? = nil, verification: SiteVerificationCoordinator? = nil, accounts: CurrentAccountStore = .shared,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         isForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.verification = verification ?? .shared
        self.client = client ?? SharedNotificationClient.shared
        self.accounts = accounts; self.defaults = defaults; self.now = now; self.isForeground = isForeground
        NotificationCenter.default.addObserver(self, selector: #selector(readStateChanged), name: SiteVerificationCoordinator.didVerify, object: self.verification)
        NotificationCenter.default.addObserver(self, selector: #selector(readStateChanged), name: .nodeSeekNotificationReadStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionClosed), name: .nodeSeekLoginSessionDidClose, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(countsChanged(_:)), name: .nodeSeekNotificationUnreadCountDidUpdate, object: nil)
    }
    deinit { loop?.cancel(); NotificationCenter.default.removeObserver(self) }

    var alertsEnabled: Bool {
        get { defaults.object(forKey: "messages.alerts-enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "messages.alerts-enabled"); if !newValue { banner?.dismiss() }; changed() }
    }
    func attach(window: UIWindow) { self.window = window; updatePresentation() }
    func updatePresentation() {
        floatingShortcut?.removeFromSuperview()
        guard let window, let current = visibleController(window.rootViewController), isForeground() else { return }
        if let nav = current.navigationController as? MessageNavigationController, !nav.isNavigationBarHidden { return }
        var ancestor: UIViewController? = current
        while let controller = ancestor {
            if controller is UIAlertController || controller is SFSafariViewController || controller is UIImagePickerController { return }
            ancestor = controller.parent
        }
        let button = MessageShortcutButton(frame: .zero)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 22
        button.onTap = { [weak self] in self?.openMessages() }
        button.update(count: unreadCount.all)
        window.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
        floatingShortcut = button
    }
    func openMessages() {
        if let navigation = visibleNavigationController(), !navigation.isNavigationBarHidden { openMessages(in: navigation) }
        else { presentMessageController(makeInbox(preferredTab)) }
    }
    private var preferredTab: NodeSeekNotificationTab {
        unreadCount.message > 0 ? .message : unreadCount.atMe > 0 ? .atMe : unreadCount.reply > 0 ? .reply : .message
    }
    private func presentMessageController(_ controller: UIViewController) {
        guard let source = visibleController(window?.rootViewController) else { return }
        floatingShortcut?.removeFromSuperview()
        let navigation = MessageNavigationController(rootViewController: controller, messageCenter: self)
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        source.present(navigation, animated: true)
    }
    func start() {
        updatePresentation()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; banner?.dismiss(); floatingShortcut?.removeFromSuperview() }
    @objc private func readStateChanged() { Task { await refresh() } }
    @objc private func sessionClosed() {
        epoch += 1; accountID = nil; ledger = InAppMessageLedger(); remoteReceipts = [:]
        banner?.dismiss(); applyCounts(.zero)
        MessageLocalNotification.removeOwnedNotifications()
    }
    @objc private func countsChanged(_ notification: Notification) {
        guard accountID != nil, let counts = NodeSeekNotificationUnreadCountEvent.unreadCount(from: notification) else { return }
        applyCounts(counts, publish: false)
    }
    private func changed() { floatingShortcut?.update(count: unreadCount.all); NotificationCenter.default.post(name: Self.didChange, object: self) }
    private func applyCounts(_ counts: NodeSeekNotificationUnreadCount, publish: Bool = true) {
        guard counts != unreadCount else { return }
        unreadCount = counts; changed()
        if publish { NodeSeekNotificationUnreadCountEvent.post(counts) }
    }

    func refresh() async {
        guard !verification.automaticRequestsPaused else { return }
        guard !checking else { refreshPending = true; return }
        checking = true
        defer {
            checking = false
            if refreshPending { refreshPending = false; Task { await self.refresh() } }
        }
        guard let account = await accounts.snapshot()?.account, account.isLoggedIn, let uid = account.nodeSeekUID else {
            accountID = nil; banner?.dismiss(); applyCounts(.zero); return
        }
        let version = epoch
        if accountID != uid {
            accountID = uid; banner?.dismiss()
            ledger = defaults.data(forKey: "messages.ledger.\(uid)").flatMap { try? JSONDecoder().decode(InAppMessageLedger.self, from: $0) } ?? InAppMessageLedger()
            applyCounts(.zero)
        }
        let counts: NodeSeekNotificationUnreadCount
        do { counts = try await client.loadUnreadCount() } catch { return }
        guard await valid(uid, epoch: version), !Task.isCancelled else { return }
        guard !verification.automaticRequestsPaused else { return }
        applyCounts(counts)
        var incoming: [InAppMessageEvent] = []
        for tab in NodeSeekNotificationTab.allCases {
            guard !verification.automaticRequestsPaused else { return }
            do {
                let events = counts.count(for: tab) > 0 ? try await events(tab: tab, uid: uid) : []
                guard await valid(uid, epoch: version), !Task.isCancelled else { return }
                incoming += ledger.ingest(events, category: "\(tab.rawValue)", now: now())
            } catch { continue }
        }
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "messages.ledger.\(uid)") }
        guard !incoming.isEmpty, await valid(uid, epoch: version), !Task.isCancelled else { return }
        NotificationCenter.default.post(name: Self.didReceive, object: self)
        let visible = incoming.filter { !isReading($0) && !hasRemoteReceipt($0) }
        guard alertsEnabled, !visible.isEmpty else { return }
        onNewEvents?(visible)
        if isForeground() {
            if let window, !(visibleController(window.rootViewController) is UIAlertController) {
                banner?.dismiss()
                let view = MessageBannerView(events: visible) { [weak self] in self?.open(visible.last!) }
                banner = view
                view.show(in: window)
            }
        } else if let latest = visible.last {
            if let onLocalEvent { await onLocalEvent(latest) }
            else if await valid(uid, epoch: version) { await MessageLocalNotification.post(latest, accounts: accounts) }
        }
    }

    private func valid(_ uid: Int, epoch version: Int) async -> Bool {
        guard epoch == version, let account = await accounts.snapshot()?.account else { return false }
        return account.isLoggedIn && account.nodeSeekUID == uid
    }
    private func events(tab: NodeSeekNotificationTab, uid: Int) async throws -> [InAppMessageEvent] {
        if tab == .message {
            return try await client.loadMessageConversations().filter { !$0.isViewed && $0.receiverID == uid }.map {
                InAppMessageEvent(id: "dm-\(uid)-\($0.maxID)", accountID: uid, category: "message", title: "\($0.senderName) 发来新私信",
                    body: "点击查看并回复", date: $0.createdAt, url: $0.conversationWebURL(currentUserID: uid), participantID: $0.senderID)
            }
        }
        let rows = try await (tab == .atMe ? client.loadAtMe() : client.loadReplies())
        return rows.filter { !$0.isViewed }.map {
            InAppMessageEvent(id: "\(tab.rawValue)-\(uid)-\($0.id)", accountID: uid, category: tab == .atMe ? "at" : "reply",
                title: "\($0.commenterName)\(tab == .atMe ? " 提到了你" : " 回复了你的主题")", body: $0.title, date: $0.createdAt,
                url: URL(string: "https://www.nodeseek.com/post-\($0.postID)-\($0.commentPage)#\($0.floorID)"), participantID: nil)
        }
    }

    private func isReading(_ event: InAppMessageEvent) -> Bool {
        guard let chat = visibleController(window?.rootViewController) as? MessageConversationViewController,
              event.category == "message" else { return false }
        return chat.model.participantID == event.participantID
    }
    func noteRemote(userInfo: [AnyHashable: Any]) {
        let kind = userInfo["type"] as? String ?? ""
        let url = userInfo["url"] as? String ?? ""
        remoteReceipts[kind + "|" + url] = now()
    }
    private func hasRemoteReceipt(_ event: InAppMessageEvent) -> Bool {
        remoteReceipts = remoteReceipts.filter { now().timeIntervalSince($0.value) < 60 }
        return remoteReceipts[event.category + "|" + (event.url?.absoluteString ?? "")] != nil
    }
    private func visibleController(_ controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController, !presented.isBeingDismissed { return visibleController(presented) }
        if let navigation = controller as? UINavigationController { return visibleController(navigation.topViewController) }
        if let tabs = controller as? UITabBarController { return visibleController(tabs.selectedViewController) }
        return controller
    }
    private func visibleNavigationController() -> UINavigationController? {
        let controller = visibleController(window?.rootViewController)
        return (controller as? UINavigationController) ?? controller?.navigationController
    }
    func openMessages(in navigation: UINavigationController) {
        let tab = preferredTab
        let current = visibleController(navigation)
        if let list = current as? NotificationViewController { list.selectTab(tab); return }
        navigation.pushViewController(makeInbox(tab), animated: true)
    }
    @discardableResult
    func show(_ controller: UIViewController) -> Bool {
        guard let source = visibleController(window?.rootViewController) else { return false }
        if source is UIAlertController {
            source.dismiss(animated: true) { [weak self] in self?.show(controller) }
        } else if let navigation = visibleNavigationController(), !navigation.isNavigationBarHidden, !(navigation is UIImagePickerController) {
            navigation.pushViewController(controller, animated: true)
        } else {
            presentMessageController(controller)
        }
        return true
    }

    func open(_ event: InAppMessageEvent) {
        Task { [weak self] in
            guard let self, await accounts.snapshot()?.account.nodeSeekUID == event.accountID,
                  let route = event.route else { return }
            banner?.dismiss()
            if isReading(event) { return }
            guard let controller = NotificationRouteViewController.make(route) else { return }
            show(controller)
        }
    }
}
