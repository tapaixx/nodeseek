import Foundation

nonisolated struct InAppMessageEvent: Sendable, Equatable {
    var id: String
    var accountID: Int
    var category: String
    var title: String
    var body: String
    var date: Date
    var url: URL?
    var participantID: Int?

    var route: PushNotificationRoute? {
        var payload: [AnyHashable: Any] = ["type": category]
        if let url { payload["url"] = url.absoluteString }
        if let floor = url?.fragment, Int(floor) != nil { payload["floor"] = floor }
        return PushNotificationRoute(userInfo: payload)
    }
}

/// 只保存事件編號與基線，不把通知正文寫入偏好設定。
nonisolated struct InAppMessageLedger: Codable, Sendable {
    private var initialized: Set<String> = []
    private var cutoffs: [String: Date] = [:]
    private var seen: [String] = []

    mutating func ingest(_ events: [InAppMessageEvent], category: String, now: Date) -> [InAppMessageEvent] {
        if initialized.insert(category).inserted {
            cutoffs[category] = events.map(\.date).max()?.addingTimeInterval(-1) ?? now.addingTimeInterval(-60)
            remember(events)
            return []
        }
        let known = Set(seen)
        let fresh = events.filter { !known.contains($0.id) && $0.date >= (cutoffs[category] ?? .distantPast) }
        remember(events)
        return fresh.sorted { $0.date < $1.date }
    }

    private mutating func remember(_ events: [InAppMessageEvent]) {
        var unique = Set<String>()
        let all = seen + events.sorted { $0.date < $1.date }.map(\.id)
        seen = Array(all.reversed().filter { unique.insert($0).inserted }.prefix(600).reversed())
    }
}
