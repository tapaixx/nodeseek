import UIKit
import UserNotifications

@MainActor
enum PushNotificationDeepLink {
    private static var pending: PushNotificationRoute?
    private static weak var navigator: PushNotificationNavigating?

    static func attach(_ navigator: PushNotificationNavigating) {
        self.navigator = navigator
        if let pending {
            self.pending = nil
            navigator.open(pending)
        }
    }

    static func handle(userInfo: [AnyHashable: Any]) {
        guard let route = PushNotificationRoute(userInfo: userInfo) else { return }
        if userInfo["ns_message_event"] != nil, let uid = userInfo["account_id"] as? Int {
            Task {
                guard await CurrentAccountStore.shared.snapshot()?.account.nodeSeekUID == uid else { return }
                handle(route)
            }
        } else {
            handle(route)
        }
    }

    static func handle(_ route: PushNotificationRoute) {
        if let navigator {
            navigator.open(route)
        } else {
            pending = route
        }
    }
}

@MainActor
protocol PushNotificationNavigating: AnyObject {
    func open(_ route: PushNotificationRoute)
}

extension AppRouter: PushNotificationNavigating {
    func open(_ route: PushNotificationRoute) {
        if case let .probe(link) = route { openProbe(link); return }
        if let controller = NotificationRouteViewController.make(route), !AppMessageCenter.shared.show(controller) { push(controller) }
    }

    private func openProbe(_ link: ProbeWidgetLink) {
        guard let navigationController else { return }
        ProbeMonitorViewController.show(link, in: navigationController)
    }
}

@MainActor
enum NotificationRouteViewController {
    static func make(_ route: PushNotificationRoute) -> UIViewController? {
        switch route {
        case let .reply(postID, page, floor, url),
             let .atMe(postID, page, floor, url):
            let post = PostSummary(
                id: postID,
                title: "",
                url: url,
                authorName: "",
                nodeName: nil,
                replyCount: 0,
                lastActivityText: nil
            )
            let detail = PostDetailRouter.createModule(
                post: post,
                page: page,
                initialAnchorID: floor
            )
            return detail
        case .checkin:
            return UserInfoWebViewController(profileURL: NodeSeekSite.boardURL, title: "签到")
        case let .webPage(url, title):
            return UserProfileRouter.makeViewController(profileURL: url, title: title)
        case .inbox, .atMeList:
            return NotificationViewController(initialTab: .atMe)
        case .replyList:
            return NotificationViewController(initialTab: .reply)
        case .messageList:
            return NotificationViewController(initialTab: .message)
        case .probe, .bannerOnly:
            return nil
        }
    }
}
