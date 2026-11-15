import XCTest
import UIKit
@testable import nodeseek

@MainActor
final class ExternalPushSettingsTests: XCTestCase {
    func testBothChannelsOpenNativeEditorsWithoutRelayAddress() {
        let controller = PushNotificationSettingsViewController(directStore: MemoryDirectPushStore(), authorizationStatusProvider: { .denied })
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 1), 2)
        for (row, title) in [(0, "企业微信机器人"), (1, "Bark")] {
            controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: row, section: 1))
            XCTAssertTrue(navigation.topViewController is DirectPushSettingsViewController)
            XCTAssertEqual(navigation.topViewController?.title, title)
            navigation.popViewController(animated: false)
        }
        let footer = controller.tableView(controller.tableView, titleForFooterInSection: 1)
        XCTAssertTrue(footer?.contains("强制关闭") == true)
        XCTAssertFalse(PushNotificationSettingsCopy.setupSteps.contains("Telegram"))
        XCTAssertFalse(PushNotificationSettingsCopy.setupSteps.contains("自行部署"))
    }

    func testManualNotificationWorksWithoutNodeSeekLogin() async throws {
        let store = MemoryDirectPushStore()
        store.values[.bark] = DirectPushConfiguration(channel: .bark, address: "https://api.day.app/fake-key")
        let sender = RecordingDirectPushSender()
        let accounts = CurrentAccountStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let controller = DirectPushSettingsViewController(channel: .bark, store: store, sender: sender, accounts: accounts)
        controller.loadViewIfNeeded()
        controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 0, section: 2))
        for _ in 0..<100 { if await sender.events.count == 1 { break }; await Task.yield() }
        let events = await sender.events
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].body.contains("App 直接发送"))
    }

    func testNativeChannelScreensInLightAndDark() async throws {
        let store = MemoryDirectPushStore()
        for channel in DirectPushChannel.allCases {
            store.values[channel] = DirectPushConfiguration(channel: channel, address: channel == .wecom ? "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=fake-secret" : "https://api.day.app/fake-secret", enabled: true, accountID: 10)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let controller = DirectPushSettingsViewController(channel: channel, store: store, sender: RecordingDirectPushSender())
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.overrideUserInterfaceStyle = style
                let navigation = UINavigationController(rootViewController: controller)
                window.rootViewController = navigation
                window.makeKeyAndVisible()
                for _ in 0..<5 { await Task.yield() }
                navigation.view.frame = window.bounds
                navigation.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: navigation.view.bounds).image { _ in navigation.view.drawHierarchy(in: navigation.view.bounds, afterScreenUpdates: true) }
                XCTAssertGreaterThan(image.pngData()?.count ?? 0, 20_000)
                let attachment = XCTAttachment(image: image)
                attachment.name = "direct-\(channel.rawValue)-\(style == .light ? "light" : "dark")"
                attachment.lifetime = .keepAlways
                add(attachment)
                let field = find(in: controller.view, id: "direct-push-address") as? UITextField
                XCTAssertTrue(field?.isSecureTextEntry == true)
                XCTAssertEqual(field?.text, "")
                window.isHidden = true
            }
        }
    }

    private func find(in view: UIView, id: String) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { self.find(in: $0, id: id) }.first
    }
}

@MainActor
final class MemoryDirectPushStore: DirectPushStoring {
    var values: [DirectPushChannel: DirectPushConfiguration] = [:]
    func configuration(_ channel: DirectPushChannel) -> DirectPushConfiguration? { values[channel] }
    func save(_ configuration: DirectPushConfiguration) throws { values[configuration.channel] = configuration }
    func remove(_ channel: DirectPushChannel) throws { values[channel] = nil }
}

nonisolated final class RecordingDirectPushSender: DirectPushSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DirectPushEvent] = []
    private var failure: DirectPushError?
    var events: [DirectPushEvent] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func send(_ event: DirectPushEvent, configuration: DirectPushConfiguration) async throws {
        if let failure = record(event) { throw failure }
    }
    private func record(_ event: DirectPushEvent) -> DirectPushError? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event)
        return failure
    }
    func setFailure(_ error: DirectPushError) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }
}
