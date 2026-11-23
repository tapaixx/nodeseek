import Foundation

@MainActor
protocol NodeSeekMessageClientProtocol {
    func loadConversation(participantID: Int) async throws -> NodeSeekMessageThread
    func send(content: String, participantID: Int) async throws
    func markViewed(ids: [Int]) async throws
}

@MainActor
final class NodeSeekMessageClient: NodeSeekMessageClientProtocol {
    private let verification: SiteVerificationCoordinator
    private let session: URLSession
    private let cookiePreparer: () async -> Void
    private let pageAction: (URL, String, [String: Any]) async throws -> [String: Any]
    private let notifications: NodeSeekNotificationClientProtocol

    init(
        session: URLSession = .shared,
        verification: SiteVerificationCoordinator? = nil,
        cookiePreparer: @escaping () async -> Void = { await NodeSeekCookieSession().prepareHTTPLoad() },
        notifications: NodeSeekNotificationClientProtocol? = nil,
        pageAction: @escaping (URL, String, [String: Any]) async throws -> [String: Any] = { url, source, arguments in
            try await withHiddenWebViewPageActionLoader(logMessage: "准备发送私信", purpose: .messageSending) { loader in
                try await loader.runPageAutomationScript(
                    pageURL: url, source: source, arguments: arguments,
                    timeoutInterval: 20, actionName: "发送私信"
                )
            }
        }
    ) {
        self.verification = verification ?? .shared
        self.session = session
        self.cookiePreparer = cookiePreparer
        self.notifications = notifications ?? NodeSeekNotificationClient()
        self.pageAction = pageAction
    }

    func loadConversation(participantID: Int) async throws -> NodeSeekMessageThread {
        guard participantID > 0 else { throw NodeSeekMessageError.invalidParticipant }
        await cookiePreparer()
        var request = URLRequest(url: NodeSeekSite.baseURL.appendingPathComponent("api/notification/message/with/\(participantID)"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        WebRequestFingerprint.applyJSONHeaders(to: &request, referer: Self.webURL(participantID: participantID))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NodeSeekMessageError.invalidResponse }
        if let challenge = NodeSeekVerificationRequired.detect(data: data, response: http, pageURL: Self.webURL(participantID: participantID)) {
            verification.require(challenge.url)
            throw challenge
        }
        if http.statusCode == 401 { throw NodeSeekMessageError.loginRequired }
        guard (200..<300).contains(http.statusCode) else {
            throw NodeSeekNotificationClientError.httpStatus(http.statusCode)
        }
        guard let thread = try? JSONDecoder().decode(NodeSeekMessageThread.self, from: data) else {
            throw NodeSeekMessageError.invalidResponse
        }
        guard thread.success else { throw NodeSeekMessageError.rejected(thread.message ?? "无法读取私信") }
        guard thread.talkTo?.memberID == participantID else { throw NodeSeekMessageError.invalidParticipant }
        verification.recordSuccess()
        return thread
    }

    func send(content: String, participantID: Int) async throws {
        guard participantID > 0 else { throw NodeSeekMessageError.invalidParticipant }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NodeSeekMessageError.rejected("请输入私信内容")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "receiverUid": participantID, "content": content, "markdown": false
        ])
        let result: [String: Any]
        do {
            result = try await pageAction(Self.webURL(participantID: participantID), Self.sendScript, [
                "bodyJSON": String(decoding: body, as: UTF8.self)
            ])
        } catch {
            throw NodeSeekMessageError.deliveryUncertain
        }
        guard result["ok"] as? Bool == true else {
            if result["reason"] as? String == "challenge" {
                if result["requiresLogin"] as? Bool == true { throw NodeSeekMessageError.loginRequired }
                let url = Self.webURL(participantID: participantID)
                verification.require(url)
                throw NodeSeekVerificationRequired(url: url)
            }
            if result["reason"] as? String == "rejected" {
                throw NodeSeekMessageError.rejected(result["message"] as? String ?? "发送失败，请稍后重试")
            }
            throw NodeSeekMessageError.deliveryUncertain
        }
    }

    func markViewed(ids: [Int]) async throws {
        try await notifications.markViewed(ids: ids, tab: .message)
    }

    static func webURL(participantID: Int) -> URL {
        NodeSeekNotificationURLBuilder.webURL(fragment: "/message?mode=talk&to=\(participantID)")
    }

    // 沿用網站會話提交，避免直接 HTTP 寫入被來源驗證拒絕；不記錄私信內容。
    static let sendScript = """
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch('/api/notification/message/send', {
        method: 'POST', credentials: 'include', signal: controller.signal,
        headers: { 'Accept': 'application/json', 'Content-Type': 'application/json' },
        body: bodyJSON
      });
      const json = await response.json();
      return {
        ok: response.ok && json.success === true,
        reason: json.success === false ? 'rejected' : 'unknown',
        message: typeof json.message === 'string' ? json.message : null
      };
    } catch (_) {
      return { ok: false, reason: 'unknown' };
    } finally {
      clearTimeout(timer);
    }
    """
}

enum NodeSeekMessageError: LocalizedError, Equatable {
    case invalidParticipant
    case invalidResponse
    case loginRequired
    case rejected(String)
    case deliveryUncertain

    var errorDescription: String? {
        switch self {
        case .invalidParticipant: return "无法确认私信对象，请返回后重试"
        case .invalidResponse: return "无法读取私信，请重试或在网页中完成验证"
        case .loginRequired: return "请先登录后使用私信"
        case .rejected(let message): return message
        case .deliveryUncertain: return "发送结果未确认，草稿已保留。请刷新对话核对后再发送，避免重复。"
        }
    }
}
