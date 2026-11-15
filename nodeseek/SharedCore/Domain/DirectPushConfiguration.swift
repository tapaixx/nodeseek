import Foundation

nonisolated enum DirectPushChannel: String, Codable, CaseIterable, Sendable {
    case wecom, bark
    var title: String { self == .wecom ? "企业微信机器人" : "Bark" }
}

nonisolated struct DirectPushConfiguration: Codable, Equatable, Sendable {
    var channel: DirectPushChannel
    var address: String = ""
    var enabled = false
    var accountID: Int?
    var group = "NodeSeek"
    var level = "active"
    var username = ""
    var password = ""
    var revision = UUID()

    func validatedURL() throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil,
              url.password == nil, url.fragment == nil else { throw DirectPushError.invalidAddress }
        switch channel {
        case .wecom:
            guard url.host == "qyapi.weixin.qq.com", url.port == nil,
                  url.path == "/cgi-bin/webhook/send",
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  query.count == 1, query[0].name == "key", Self.validKey(query[0].value ?? "") else { throw DirectPushError.invalidAddress }
        case .bark:
            guard url.query == nil, Self.validKey(url.lastPathComponent),
                  !["push", ""].contains(url.lastPathComponent), ["active", "passive", "timeSensitive"].contains(level),
                  group.utf8.count <= 128, username.isEmpty == password.isEmpty else { throw DirectPushError.invalidAddress }
        }
        return url
    }

    private static func validKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
            && value.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/?#&;="))) == nil
    }
}

nonisolated struct DirectPushEvent: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var type: String
    var url: URL?
    var date: Date
}

nonisolated enum DirectPushError: LocalizedError, Equatable {
    case invalidAddress, credentials, loginRequired, rejected(Int), uncertain
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "地址或配置格式有误，请检查 HTTPS 地址、密钥及鉴权信息"
        case .credentials: return "无法更新本机保存的密钥，请重试"
        case .loginRequired: return "请先登录 NodeSeek，再开启自动转发"
        case .rejected(let code): return "服务拒绝通知（错误码 \(code)），请检查渠道配置"
        case .uncertain: return "投递结果未确认，请先核对收件情况，避免重复发送"
        }
    }
}

nonisolated enum DirectPushPayload {
    static func request(configuration: DirectPushConfiguration, event: DirectPushEvent) throws -> URLRequest {
        let address = try configuration.validatedURL()
        var target = address
        var payload: [String: Any]
        if configuration.channel == .wecom {
            let head = "### \(escape(clip(event.title, bytes: 200)))\n"
            var suffix = event.url.map { "\n\n[查看详情](\($0.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))" } ?? ""
            if suffix.utf8.count > 1800 { suffix = "" }
            payload = ["msgtype": "markdown", "markdown": ["content": head + clip(escape(event.body), bytes: 4096 - head.utf8.count - suffix.utf8.count) + suffix]]
        } else {
            let key = address.lastPathComponent
            target = address.deletingLastPathComponent().appendingPathComponent("push")
            var link = URLComponents(string: "nsconnect://notification")!
            link.queryItems = [URLQueryItem(name: "type", value: event.type)]
            if let url = event.url, url.absoluteString.utf8.count < 700 { link.queryItems?.append(URLQueryItem(name: "url", value: url.absoluteString)) }
            payload = ["device_key": key, "title": clip(event.title, bytes: 200), "body": clip(event.body, bytes: 1800),
                       "url": link.url!.absoluteString, "group": configuration.group, "level": configuration.level,
                       "id": clip(event.id, bytes: 64), "isArchive": 1]
            while let data = try? JSONSerialization.data(withJSONObject: payload), data.count > 3500 {
                let body = payload["body"] as? String ?? ""
                if !body.isEmpty { payload["body"] = clip(body, bytes: max(0, body.utf8.count - 300)) }
                else { payload["title"] = "NodeSeek 通知"; payload["group"] = "NodeSeek"; break }
            }
        }
        var request = URLRequest(url: target, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if configuration.channel == .bark, !configuration.username.isEmpty {
            let token = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func check(data: Data, status: Int, channel: DirectPushChannel) throws {
        guard status == 200 else { throw DirectPushError.rejected(status) }
        guard data.count < 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object[channel == .wecom ? "errcode" : "code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID() else { throw DirectPushError.uncertain }
        guard code.intValue == (channel == .wecom ? 0 : 200) else { throw DirectPushError.rejected(code.intValue) }
    }

    static func clip(_ value: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        guard value.utf8.count > bytes else { return value }
        var output = ""
        for character in value {
            if output.utf8.count + String(character).utf8.count + 3 > bytes { break }
            output.append(character)
        }
        return bytes >= 3 ? output + "…" : output
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "*", with: "\\*")
    }
}
