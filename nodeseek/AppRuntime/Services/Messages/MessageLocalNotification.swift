import Foundation
import UserNotifications

@MainActor
enum MessageLocalNotification {
    static let prefix = "ns-message-"
    static func post(_ event: InAppMessageEvent, accounts: CurrentAccountStore) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard !Task.isCancelled, [.authorized, .provisional, .ephemeral].contains(status),
              await accounts.snapshot()?.account.nodeSeekUID == event.accountID else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        var info: [AnyHashable: Any] = ["type": event.category, "account_id": event.accountID, "ns_message_event": event.id]
        if let url = event.url { info["url"] = url.absoluteString }
        content.userInfo = info
        content.threadIdentifier = "nodeseek-\(event.accountID)"
        let request = UNNotificationRequest(identifier: prefix + event.id, content: content, trigger: nil)
        try? await center.add(request)
    }
    static func removeOwnedNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
        }
        center.getDeliveredNotifications { notices in
            center.removeDeliveredNotifications(withIdentifiers: notices.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}
