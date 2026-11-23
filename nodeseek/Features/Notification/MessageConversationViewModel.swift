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
    private(set) var readStateWarning: String?
    private(set) var deliveryUncertain = false
    private(set) var participantProfile: UserProfileRecord?
    private(set) var latestDiscussion: UserDiscussionRecord?
    var draft = ""
    var onChange: (() -> Void)?
    private let client: NodeSeekMessageClientProtocol
    private let currentAccountStore: CurrentAccountStore
    private let profileClient: MessageParticipantLoading?
    private var markedIDs: Set<Int> = []
    private var isSyncingReadState = false
    private var loadRevision = 0

    init(
        participantID: Int,
        participantName: String = "私信",
        client: NodeSeekMessageClientProtocol,
        currentAccountStore: CurrentAccountStore = .shared,
        profileClient: MessageParticipantLoading? = nil
    ) {
        self.participantID = participantID
        self.participantName = participantName
        self.client = client
        self.currentAccountStore = currentAccountStore
        self.profileClient = profileClient
    }

    func loadParticipant() async {
        guard let profileClient else { return }
        do {
            async let profile = profileClient.loadProfile(uid: participantID)
            async let discussions = try? profileClient.loadDiscussions(uid: participantID, page: 1)
            let loaded = try await profile
            guard loaded.uid == participantID, !Task.isCancelled else { return }
            participantProfile = loaded
            participantName = loaded.name
            latestDiscussion = await discussions?.first
            onChange?()
        } catch {
            // 資料卡失敗不應阻止讀取與發送私信，使用者仍可進入完整個人頁重試。
        }
    }

    func load() async { await load(afterSend: false) }

    private func load(afterSend: Bool) async {
        guard afterSend || (!isLoading && !isSending) else { return }
        loadRevision += 1
        let revision = loadRevision
        isLoading = true
        onChange?()
        var loadedUserID: Int?
        var unread: [Int] = []
        do {
            let uid = try await accountID()
            let thread = try await client.loadConversation(participantID: participantID)
            try Task.checkCancellation()
            guard try await accountID() == uid else { throw NodeSeekMessageError.loginRequired }
            guard revision == loadRevision else { return }
            guard thread.talkTo?.memberID == participantID else { throw NodeSeekMessageError.invalidParticipant }
            currentUserID = uid
            participantName = thread.talkTo?.memberName ?? participantName
            messages = thread.messages(participantID: participantID, currentUserID: uid)
            hasLoaded = true
            if !deliveryUncertain && !isSending { errorMessage = nil }
            loadedUserID = uid
            unread = messages.filter { $0.receiverID == uid && !$0.viewed && !markedIDs.contains($0.id) }.map(\.id)
            if unread.isEmpty { readStateWarning = nil }
        } catch {
            guard revision == loadRevision else { return }
            if !Task.isCancelled && !deliveryUncertain && !isSending {
                errorMessage = afterSend ? "私信已发送，更新对话失败，请下拉刷新" : error.localizedDescription
            }
        }
        // 内容读取完成即可回复，标记已读的网页请求不能继续占用加载状态。
        isLoading = false
        onChange?()
        if let uid = loadedUserID { await syncReadState(ids: unread, userID: uid) }
    }

    private func syncReadState(ids: [Int], userID: Int) async {
        guard !ids.isEmpty, !isSyncingReadState, !Task.isCancelled else { return }
        isSyncingReadState = true
        defer { isSyncingReadState = false; onChange?() }
        do {
            try await client.markViewed(ids: ids)
            guard !Task.isCancelled, try await accountID() == userID else { return }
            markedIDs.formUnion(ids)
            readStateWarning = nil
            NotificationCenter.default.post(name: .nodeSeekNotificationReadStateDidChange, object: nil)
        } catch {
            guard !Task.isCancelled, (try? await accountID()) == userID else { return }
            readStateWarning = "已读状态同步失败，不影响发送消息，将在刷新时重试"
        }
    }

    func send() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasLoaded, !isSending, !content.isEmpty, !deliveryUncertain else { return }
        loadRevision += 1
        isLoading = false
        isSending = true
        errorMessage = nil
        onChange?()
        do {
            let uid = try await accountID()
            try await client.send(content: content, participantID: participantID)
            guard try await accountID() == uid else { throw NodeSeekMessageError.loginRequired }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == content { draft = "" }
            isSending = false
            await load(afterSend: true)
            return
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
            readStateWarning = nil
            throw NodeSeekMessageError.loginRequired
        }
        if let currentUserID, currentUserID != uid {
            messages = []
            draft = ""
            hasLoaded = false
            readStateWarning = nil
            throw NodeSeekMessageError.loginRequired
        }
        currentUserID = uid
        return uid
    }
}
