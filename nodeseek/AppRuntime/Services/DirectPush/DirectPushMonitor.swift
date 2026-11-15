import Foundation

/// App 可執行時讀取站內通知；不建立常駐連線，也不修改站內已讀狀態。
@MainActor
final class DirectPushMonitor {
    static let shared = DirectPushMonitor()
    private let store: DirectPushStoring
    private let client: NodeSeekNotificationClientProtocol
    private let sender: DirectPushSending
    private let accounts: CurrentAccountStore
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var checking = false

    init(store: DirectPushStoring = DirectPushStore.shared, client: NodeSeekNotificationClientProtocol? = nil,
         sender: DirectPushSending = DirectPushSender.shared, accounts: CurrentAccountStore = .shared,
         defaults: UserDefaults = .standard) {
        self.store = store
        self.client = client ?? SharedNotificationClient.shared
        self.sender = sender
        self.accounts = accounts
        self.defaults = defaults
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: DirectPushStore.didChange, object: nil)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    @objc private func settingsChanged() { stop(); start() }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let account = await accounts.snapshot()?.account, account.isLoggedIn,
              let uid = account.nodeSeekUID else { return }
        let configurations = DirectPushChannel.allCases.compactMap { store.configuration($0) }.filter { $0.enabled && $0.accountID == uid }
        guard !configurations.isEmpty else { return }
        // 某一類讀取失敗不能建立基線，也不應阻止其他類別。
        for tab in NodeSeekNotificationTab.allCases {
            guard !Task.isCancelled else { return }
            do {
                let events = try await events(tab: tab, uid: uid)
                guard await accounts.snapshot()?.account.nodeSeekUID == uid else { return }
                await withTaskGroup(of: Void.self) { group in
                    for config in configurations {
                        group.addTask { @MainActor in
                            await self.forward(events, tab: tab, uid: uid, config: config)
                        }
                    }
                }
            } catch {
                for config in configurations {
                    defaults.set("站内通知读取失败，请确认登录状态并在前台打开通知页", forKey: Self.statusKey(config.channel))
                }
            }
        }
    }

    private func forward(_ events: [DirectPushEvent], tab: NodeSeekNotificationTab, uid: Int, config: DirectPushConfiguration) async {
        guard !Task.isCancelled, store.configuration(config.channel) == config,
              await accounts.snapshot()?.account.nodeSeekUID == uid else { return }
        let key = "direct-push.seen.\(config.channel.rawValue).\(uid).\(config.revision).\(tab.rawValue)"
        let previous = defaults.stringArray(forKey: key)
        let seen = Set(previous ?? [])
        if previous == nil {
            defaults.set(Array(events.sorted { $0.date < $1.date }.map(\.id).suffix(500)), forKey: key)
            return
        }
        let fresh = events.filter { !seen.contains($0.id) }.sorted { $0.date < $1.date }.prefix(5)
        var retained = previous ?? []
        for event in fresh {
            guard !Task.isCancelled, store.configuration(config.channel) == config,
                  await accounts.snapshot()?.account.nodeSeekUID == uid else { return }
            // 僅記錄即將投遞的事件；超出本輪預算的事件留待下次檢查。
            retained.append(event.id)
            defaults.set(Array(retained.suffix(500)), forKey: key)
            do {
                try await sender.send(event, configuration: config)
                defaults.set("已投递 · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))", forKey: Self.statusKey(config.channel))
            } catch is CancellationError { return }
            catch {
                defaults.set((error as? DirectPushError)?.localizedDescription ?? "通知投递失败，请检查渠道配置", forKey: Self.statusKey(config.channel))
            }
        }
    }

    static func statusKey(_ channel: DirectPushChannel) -> String { "direct-push.status.\(channel.rawValue)" }

    private func events(tab: NodeSeekNotificationTab, uid: Int) async throws -> [DirectPushEvent] {
        if tab == .message {
            return try await client.loadMessageConversations().filter { !$0.isViewed && $0.receiverID == uid }.map {
                DirectPushEvent(id: "dm-\(uid)-\($0.maxID)", title: "\($0.senderName) 发来私信", body: "你有一条新的私信，点击查看", type: "message", url: $0.conversationWebURL(currentUserID: uid), date: $0.createdAt)
            }
        }
        let rows = try await (tab == .atMe ? client.loadAtMe() : client.loadReplies())
        return rows.filter { !$0.isViewed }.map {
            let raw = "https://www.nodeseek.com/post-\($0.postID)-\($0.commentPage)#\($0.floorID)"
            return DirectPushEvent(id: "\(tab.rawValue)-\(uid)-\($0.id)", title: "\($0.commenterName)\(tab == .atMe ? " 提到了你" : " 回复了你的主题")", body: $0.title, type: tab == .atMe ? "at" : "reply", url: URL(string: raw), date: $0.createdAt)
        }
    }
}
