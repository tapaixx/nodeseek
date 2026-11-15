import Foundation

@MainActor
final class MessageConversationViewModel {
    let participantID: Int
    private(set) var participantName: String
    private(set) var messages: [NodeSeekDirectMessage] = []
    private(set) var currentUserID: Int?
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var deliveryUncertain = false
    var draft = ""
    var onChange: (() -> Void)?
    private let client: NodeSeekMessageClientProtocol
    private let currentAccountStore: CurrentAccountStore
    private var markedIDs: Set<Int> = []

    init(
        participantID: Int,
        participantName: String = "私信",
        client: NodeSeekMessageClientProtocol,
        currentAccountStore: CurrentAccountStore = .shared
    ) {
        self.participantID = participantID
        self.participantName = participantName
        self.client = client
        self.currentAccountStore = currentAccountStore
    }

    func load() async {
        guard !isLoading, !isSending else { return }
        isLoading = true
        onChange?()
        defer { isLoading = false; onChange?() }
        do {
            let uid = try await accountID()
            let thread = try await client.loadConversation(participantID: participantID)
            try Task.checkCancellation()
            guard try await accountID() == uid else { throw NodeSeekMessageError.loginRequired }
            guard thread.talkTo?.memberID == participantID else { throw NodeSeekMessageError.invalidParticipant }
            currentUserID = uid
            participantName = thread.talkTo?.memberName ?? participantName
            messages = thread.messages(participantID: participantID, currentUserID: uid)
            hasLoaded = true
            if !deliveryUncertain { errorMessage = nil }
            onChange?()
            let unread = messages.filter { $0.receiverID == uid && !$0.viewed && !markedIDs.contains($0.id) }.map(\.id)
            if !unread.isEmpty, !Task.isCancelled {
                do {
                    try await client.markViewed(ids: unread)
                    markedIDs.formUnion(unread)
                    NotificationCenter.default.post(name: .nodeSeekNotificationReadStateDidChange, object: nil)
                } catch {
                    if !deliveryUncertain { errorMessage = "私信已加载，已读状态同步失败，请下拉刷新重试" }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !isLoading, !content.isEmpty, !deliveryUncertain else { return }
        isSending = true
        errorMessage = nil
        onChange?()
        do {
            let uid = try await accountID()
            try await client.send(content: content, participantID: participantID)
            guard try await accountID() == uid else { throw NodeSeekMessageError.loginRequired }
            draft = ""
            isSending = false
            await load()
            if errorMessage != nil { errorMessage = "私信已发送，更新对话失败，请下拉刷新" }
        } catch {
            deliveryUncertain = (error as? NodeSeekMessageError) == .deliveryUncertain
            errorMessage = error.localizedDescription
        }
        isSending = false
        onChange?()
    }

    func acknowledgeUncertainDelivery() {
        deliveryUncertain = false
        errorMessage = nil
        onChange?()
    }

    private func accountID() async throws -> Int {
        guard let account = await currentAccountStore.snapshot()?.account,
              account.isLoggedIn, let uid = account.nodeSeekUID else {
            messages = []
            draft = ""
            hasLoaded = false
            throw NodeSeekMessageError.loginRequired
        }
        if let currentUserID, currentUserID != uid {
            messages = []
            draft = ""
            hasLoaded = false
            throw NodeSeekMessageError.loginRequired
        }
        currentUserID = uid
        return uid
    }
}
