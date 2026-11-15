import Foundation

/// Bark 僅可開啟站內通知；外部 URL 不得經此入口進入 WebView。
enum ExternalPushLink {
    nonisolated static func route(from url: URL) -> PushNotificationRoute? {
        guard url.scheme?.lowercased() == "nsconnect", url.host?.lowercased() == "notification",
              url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        guard items.allSatisfy({ ["type", "url"].contains($0.name) }),
              items.filter({ $0.name == "type" }).count == 1,
              items.filter({ $0.name == "url" }).count <= 1,
              let type = items.first(where: { $0.name == "type" })?.value,
              ["reply", "at", "mention", "message", "dm", "checkin", "inbox", "notification", "other"].contains(type) else { return nil }
        var info: [AnyHashable: Any] = ["type": type]
        if let raw = items.first(where: { $0.name == "url" })?.value {
            guard let target = URL(string: raw), target.scheme == "https", NodeSeekSite.isNodeSeekHost(target),
                  target.user == nil, target.password == nil, target.port == nil || target.port == 443 else { return nil }
            guard target.path == "/notification" || target.path == "/board" || isPost(target) else { return nil }
            info["url"] = target.absoluteString
            if let floor = target.fragment, !floor.isEmpty, floor.allSatisfy(\.isNumber) { info["floor"] = floor }
            if type == "reply", !isPost(target) { return .replyList }
        }
        if type == "reply", info["url"] == nil { return .replyList }
        return PushNotificationRoute(userInfo: info)
    }

    private nonisolated static func isPost(_ url: URL) -> Bool {
        url.path.range(of: #"^/post-[0-9]+(?:-[0-9]+)?$"#, options: .regularExpression) != nil
    }
}
