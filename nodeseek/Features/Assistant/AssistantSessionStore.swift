import Foundation
import SwiftUI
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 全局跨帖子 AI 助手状态中心与本地持久化存储。
@MainActor
final class AssistantSessionStore: ObservableObject {
    static let shared = AssistantSessionStore()

    private static let maxStoredSessions = 20
    private static let maxTurnsPerSession = 80

    @Published private(set) var sessions: [AssistantSession] = []
    @Published var activeSessionID: UUID
    @Published var currentPageContext: AssistantContextSnapshot?
    @Published var attachCurrentContext: Bool = true
    @Published private(set) var isGenerating: Bool = false
    @Published var hasUnreadReply: Bool = false
    @Published var isPanelPresented: Bool = false
    @Published var apiConfiguration: ChatAssistantAPIConfiguration?
    @Published var usesCustomAPI: Bool

    /// 当前页面的回复草稿回调（仅在可回复的帖子/聊天页有效）。
    var currentDraftHandler: ((String) -> Bool)?
    /// 当前页面上下文 ID，用于离开页面时防止误清其他页面的上下文。
    private var currentContextOwnerID: String?

    private let storageURL: URL
    private let settings: FloatingAssistantSettings
    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?

    var activeSession: AssistantSession {
        if let found = sessions.first(where: { $0.id == activeSessionID }) {
            return found
        }
        return sessions.first ?? AssistantSession()
    }

    var canApplyDraftToCurrentPage: Bool {
        currentDraftHandler != nil && currentPageContext != nil
    }

    var isOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    var isReadyToSend: Bool {
        usesCustomAPI ? apiConfiguration != nil : isOnDeviceAvailable
    }

    var needsExternalConsent: Bool {
        guard usesCustomAPI, let apiConfiguration else { return false }
        return !settings.hasConsentedExternalEndpoint(apiConfiguration.endpoint)
    }

    init(
        storageURL: URL? = nil,
        settings: FloatingAssistantSettings = .shared,
        configuration: ChatAssistantAPIConfiguration? = ChatAssistantAPIStore.load()
    ) {
        self.settings = settings
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.apiConfiguration = configuration
        self.usesCustomAPI = configuration != nil

        let loaded = Self.loadSessions(from: self.storageURL)
        if loaded.isEmpty {
            let initial = AssistantSession()
            self.sessions = [initial]
            self.activeSessionID = initial.id
        } else {
            self.sessions = loaded
            self.activeSessionID = loaded[0].id
        }
    }

    // MARK: - 页面上下文同步

    func updateCurrentPostContext(
        postID: String,
        title: String,
        authorName: String?,
        commentCount: Int,
        messages: [ChatAssistantMessage],
        draftHandler: ((String) -> Bool)?
    ) {
        let contextID = "post-\(postID)"
        let subtitleParts: [String] = [
            authorName.map { "@\($0)" },
            commentCount > 0 ? String(format: ChatAssistantText.text("commentCountFormat"), commentCount) : nil
        ].compactMap { $0 }

        let snapshot = AssistantContextSnapshot(
            id: contextID,
            kind: .post,
            postID: postID,
            title: title,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            messages: messages,
            capturedAt: Date()
        )
        let isSwitchingPost = currentPageContext?.id != contextID
        currentPageContext = snapshot
        currentContextOwnerID = contextID
        currentDraftHandler = draftHandler
        if isSwitchingPost {
            // 切换到新帖子时默认开启附带当前帖子，方便直接提问或跨帖对比。
            attachCurrentContext = true
        }
    }

    func clearCurrentPostContext(postID: String) {
        let contextID = "post-\(postID)"
        guard currentContextOwnerID == contextID else { return }
        currentPageContext = nil
        currentContextOwnerID = nil
        currentDraftHandler = nil
    }

    func setTransientChatContext(
        id: String,
        title: String,
        messages: [ChatAssistantMessage],
        draftHandler: ((String) -> Bool)?
    ) {
        let snapshot = AssistantContextSnapshot(
            id: id,
            kind: .chat,
            postID: nil,
            title: title,
            subtitle: nil,
            messages: messages,
            capturedAt: Date()
        )
        currentPageContext = snapshot
        currentContextOwnerID = id
        currentDraftHandler = draftHandler
        attachCurrentContext = true
    }

    // MARK: - 配置管理

    func updateAPIConfiguration(_ updated: ChatAssistantAPIConfiguration?) {
        if updated?.endpoint != apiConfiguration?.endpoint {
            settings.clearExternalConsent()
        }
        apiConfiguration = updated
        usesCustomAPI = updated != nil
    }

    func confirmExternalEndpointConsent() {
        guard let apiConfiguration else { return }
        settings.markConsentedExternalEndpoint(apiConfiguration.endpoint)
    }

    // MARK: - 会话管理

    @discardableResult
    func startNewSession() -> AssistantSession {
        cancelGeneration()
        let session = AssistantSession()
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        trimAndPersist()
        return session
    }

    func selectSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        cancelGeneration()
        activeSessionID = id
    }

    func deleteSession(_ id: UUID) {
        if activeSessionID == id {
            cancelGeneration()
        }
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            let fresh = AssistantSession()
            sessions = [fresh]
            activeSessionID = fresh.id
        } else if !sessions.contains(where: { $0.id == activeSessionID }) {
            activeSessionID = sessions[0].id
        }
        trimAndPersist()
    }

    func clearActiveSession() {
        cancelGeneration()
        mutateActiveSession { session in
            session.turns = []
            session.referencedContexts = []
            session.title = ""
            session.updatedAt = Date()
        }
    }

    func removeReferencedContext(id: String) {
        mutateActiveSession { session in
            session.referencedContexts.removeAll { $0.id == id }
            session.updatedAt = Date()
        }
    }

    func applyDraftToCurrentPage(_ text: String) -> Bool {
        guard let currentDraftHandler else { return false }
        return currentDraftHandler(text)
    }

    // MARK: - 发送与流式生成

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isGenerating = false
    }

    func sendMessage(
        _ rawText: String,
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        let prompt = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }

        let contextToAttach: AssistantContextSnapshot? = attachCurrentContext ? currentPageContext : nil
        let targetSessionID = activeSessionID

        // 先构建发送给模型的消息列表（此时尚未把本轮 user 写入 turns，避免重复）
        let sessionSnapshot = activeSession
        let apiMessages = AssistantPromptBuilder.buildMessages(
            session: sessionSnapshot,
            activeContext: contextToAttach,
            userPrompt: prompt
        )

        var attachedRefs: [AssistantAttachedReference] = []
        if let contextToAttach {
            attachedRefs.append(
                AssistantAttachedReference(
                    id: contextToAttach.id,
                    postID: contextToAttach.postID,
                    title: contextToAttach.title,
                    kind: contextToAttach.kind
                )
            )
        }

        let userTurn = AssistantChatTurn(
            role: .user,
            content: prompt,
            attachedReferences: attachedRefs
        )
        let placeholderAssistantTurn = AssistantChatTurn(
            role: .assistant,
            content: ""
        )

        mutateSession(id: targetSessionID) { session in
            if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.title = prompt.count <= 22 ? prompt : String(prompt.prefix(22)) + "…"
            }
            if let contextToAttach {
                session.referencedContexts.removeAll { $0.id == contextToAttach.id }
                session.referencedContexts.append(contextToAttach)
                if session.referencedContexts.count > 6 {
                    session.referencedContexts = Array(session.referencedContexts.suffix(6))
                }
            }
            session.turns.append(userTurn)
            session.turns.append(placeholderAssistantTurn)
            session.updatedAt = Date()
        }

        let assistantTurnID = placeholderAssistantTurn.id
        let useCustom = usesCustomAPI
        let config = apiConfiguration

        let requestID = UUID()
        generationID = requestID
        isGenerating = true
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // 已停止的旧任务可能晚于替代任务结束，不能覆盖新任务状态。
                if self.generationID == requestID {
                    self.isGenerating = false
                    self.generationTask = nil
                    self.generationID = nil
                }
                self.trimAndPersist()
            }

            do {
                let finalText: String
                if useCustom, let config {
                    if let transport {
                        finalText = try await ChatAssistantAPI().chat(
                            configuration: config,
                            messages: apiMessages,
                            transport: transport
                        )
                    } else {
                        finalText = try await ChatAssistantAPI().streamChat(
                            configuration: config,
                            messages: apiMessages
                        ) { [weak self] partial in
                            guard let self, self.generationID == requestID, !Task.isCancelled else { return }
                            self.updateTurnContent(
                                sessionID: targetSessionID,
                                turnID: assistantTurnID,
                                content: partial,
                                isError: false
                            )
                        }
                    }
                } else {
                    finalText = try await self.generateOnDevice(messages: apiMessages)
                }

                try Task.checkCancellation()
                let cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    self.updateTurnContent(
                        sessionID: targetSessionID,
                        turnID: assistantTurnID,
                        content: ChatAssistantText.text("failed"),
                        isError: true
                    )
                } else {
                    self.updateTurnContent(
                        sessionID: targetSessionID,
                        turnID: assistantTurnID,
                        content: cleaned,
                        isError: false
                    )
                    if !self.isPanelPresented {
                        self.hasUnreadReply = true
                    }
                }
            } catch is CancellationError {
                // 用户手动停止：若已有部分输出则保留，否则移除空气泡
                self.finalizeCancelledTurn(sessionID: targetSessionID, turnID: assistantTurnID)
            } catch {
                if Task.isCancelled {
                    self.finalizeCancelledTurn(sessionID: targetSessionID, turnID: assistantTurnID)
                } else {
                    let messageKey = useCustom ? "apiFailed" : "failed"
                    self.updateTurnContent(
                        sessionID: targetSessionID,
                        turnID: assistantTurnID,
                        content: ChatAssistantText.text(messageKey),
                        isError: true
                    )
                }
            }
        }
    }

    func regenerateLastReply() {
        guard !isGenerating else { return }
        let session = activeSession
        guard let lastUserIndex = session.turns.lastIndex(where: { $0.role == .user }) else { return }
        let lastPrompt = session.turns[lastUserIndex].content
        mutateActiveSession { current in
            current.turns.removeSubrange(lastUserIndex..<current.turns.count)
            current.updatedAt = Date()
        }
        sendMessage(lastPrompt)
    }

    // MARK: - Private Helpers

    private func generateOnDevice(messages: [ChatAssistantAPIMessage]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let system = messages.first(where: { $0.role == "system" })?.content ?? ""
            let transcript = messages
                .filter { $0.role != "system" }
                .map { "\($0.role): \($0.content)" }
                .joined(separator: "\n\n")
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(
                to: transcript,
                options: GenerationOptions(maximumResponseTokens: 600)
            ).content
        }
        #endif
        throw ChatAssistantAPI.Failure.rejected
    }

    private func updateTurnContent(sessionID: UUID, turnID: UUID, content: String, isError: Bool) {
        guard let sIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let tIndex = sessions[sIndex].turns.firstIndex(where: { $0.id == turnID }) else {
            return
        }
        sessions[sIndex].turns[tIndex].content = content
        sessions[sIndex].turns[tIndex].isError = isError
        sessions[sIndex].updatedAt = Date()
    }

    private func finalizeCancelledTurn(sessionID: UUID, turnID: UUID) {
        guard let sIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let tIndex = sessions[sIndex].turns.firstIndex(where: { $0.id == turnID }) else {
            return
        }
        if sessions[sIndex].turns[tIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[sIndex].turns.remove(at: tIndex)
        }
    }

    private func mutateActiveSession(_ mutate: (inout AssistantSession) -> Void) {
        mutateSession(id: activeSessionID, mutate)
    }

    private func mutateSession(id: UUID, _ mutate: (inout AssistantSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        if sessions[index].turns.count > Self.maxTurnsPerSession {
            sessions[index].turns = Array(sessions[index].turns.suffix(Self.maxTurnsPerSession))
        }
        // 将刚更新的会话置顶
        if index != 0 {
            let updated = sessions.remove(at: index)
            sessions.insert(updated, at: 0)
        }
        trimAndPersist()
    }

    private func trimAndPersist() {
        if sessions.count > Self.maxStoredSessions {
            sessions = Array(sessions.prefix(Self.maxStoredSessions))
        }
        Self.saveSessions(sessions, to: storageURL)
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("nodeseek-ai-assistant", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    private static func loadSessions(from url: URL) -> [AssistantSession] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AssistantSession].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveSessions(_ sessions: [AssistantSession], to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic)
        } catch {
            // 持久化失败不阻塞主流程
        }
    }
}
