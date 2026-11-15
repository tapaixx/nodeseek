import Foundation

/// 前台提示、通知頁與外部渠道共用短效快取及同一筆進行中的讀取。
@MainActor
final class SharedNotificationClient: NodeSeekNotificationClientProtocol {
    static let shared = SharedNotificationClient()
    private let base: NodeSeekNotificationClientProtocol
    private let accounts: CurrentAccountStore
    private let counts = NotificationReadCache<NodeSeekNotificationUnreadCount>(ttl: 5)
    private let mentions = NotificationReadCache<[NodeSeekNotificationRecord]>(ttl: 10)
    private let replies = NotificationReadCache<[NodeSeekNotificationRecord]>(ttl: 10)
    private let messages = NotificationReadCache<[NodeSeekMessageConversationRecord]>(ttl: 10)

    init(base: NodeSeekNotificationClientProtocol? = nil, accounts: CurrentAccountStore = .shared) {
        self.base = base ?? NodeSeekNotificationClient()
        self.accounts = accounts
        for name in [Notification.Name.nodeSeekLoginSessionDidClose, .nodeSeekNotificationReadStateDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: name, object: nil)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func invalidate() {
        counts.clear(); mentions.clear(); replies.clear(); messages.clear()
    }
    private func accountID() async -> Int? { await accounts.snapshot()?.account.nodeSeekUID }
    private func validate(_ uid: Int?) async throws {
        guard await accountID() == uid else { throw CancellationError() }
    }
    @MainActor func loadUnreadCount() async throws -> NodeSeekNotificationUnreadCount {
        let uid = await accountID()
        let result = try await counts.value(scope: uid) { try await self.base.loadUnreadCount() }
        try await validate(uid)
        return result
    }
    @MainActor func loadAtMe() async throws -> [NodeSeekNotificationRecord] {
        let uid = await accountID()
        let result = try await mentions.value(scope: uid) { try await self.base.loadAtMe() }
        try await validate(uid)
        return result
    }
    @MainActor func loadReplies() async throws -> [NodeSeekNotificationRecord] {
        let uid = await accountID()
        let result = try await replies.value(scope: uid) { try await self.base.loadReplies() }
        try await validate(uid)
        return result
    }
    @MainActor func loadMessageConversations() async throws -> [NodeSeekMessageConversationRecord] {
        let uid = await accountID()
        let result = try await messages.value(scope: uid) { try await self.base.loadMessageConversations() }
        try await validate(uid)
        return result
    }
    @MainActor func markViewed(ids: [Int], tab: NodeSeekNotificationTab) async throws {
        try await base.markViewed(ids: ids, tab: tab)
        invalidate()
    }
    @MainActor func markAllViewed(tab: NodeSeekNotificationTab) async throws {
        try await base.markAllViewed(tab: tab)
        invalidate()
    }
}

@MainActor
private final class NotificationReadCache<Value: Sendable> {
    private let ttl: TimeInterval
    private var cached: (uid: Int?, date: Date, value: Value)?
    private var pending: (uid: Int?, id: UUID, task: Task<Value, Error>)?
    private var generation = 0
    init(ttl: TimeInterval) { self.ttl = ttl }
    // Swift 6.2 的最佳化會在泛型類別的隱含隔離解構子崩潰，空解構子保留原有釋放行為。
    deinit {}
    func clear() { generation += 1; cached = nil; pending?.task.cancel(); pending = nil }
    func value(scope: Int?, loader: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let cached, scope != nil, cached.uid == scope, Date().timeIntervalSince(cached.date) < ttl { return cached.value }
        if let pending, pending.uid == scope {
            let epoch = generation
            let result = try await pending.task.value
            guard epoch == generation else { throw CancellationError() }
            return result
        }
        if pending != nil || (cached != nil && cached?.uid != scope) { clear() }
        let epoch = generation, id = UUID()
        let task = Task { try await loader() }
        pending = (scope, id, task)
        defer { if pending?.id == id { pending = nil } }
        let result = try await task.value
        guard epoch == generation else { throw CancellationError() }
        if scope != nil { cached = (scope, Date(), result) }
        return result
    }
}
