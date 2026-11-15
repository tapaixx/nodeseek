import XCTest
import UIKit
@testable import nodeseek

@MainActor
final class ExternalPushSettingsTests: XCTestCase {
    func testBothChannelsOpenCorrectServicePage() throws {
        let suite = "external-push-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PushRelaySettingsStore(defaults: defaults)
        store.save(try XCTUnwrap(PushRelayAddress.normalized("https://notify.example.com")))
        var opened: [URL] = []
        let controller = PushNotificationSettingsViewController(relayStore: store, openRelay: { opened.append($0) }, authorizationStatusProvider: { .denied })
        controller.loadViewIfNeeded()
        for row in [1, 2] { controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: row, section: 1)) }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://notify.example.com/channels#wecom", "https://notify.example.com/channels#bark"])
        XCTAssertEqual(defaults.string(forKey: "push.relay.baseURL"), "https://notify.example.com")
        store.save(nil)
        XCTAssertNil(store.baseURL)
    }

    func testMissingServiceOffersSetupInsteadOfFakeEnabledStatus() throws {
        let suite = "external-push-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PushNotificationSettingsViewController(relayStore: PushRelaySettingsStore(defaults: defaults), authorizationStatusProvider: { .notDetermined })
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(cell.detailTextLabel?.text, "填写已部署的 ns-apns 地址")
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 1), 3)
    }

    func testChannelsLayoutInLightAndDark() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let suite = "external-push-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PushNotificationSettingsViewController(relayStore: PushRelaySettingsStore(defaults: defaults), authorizationStatusProvider: { .denied })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            let navigation = UINavigationController(rootViewController: controller)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            for _ in 0..<10 { await Task.yield() }
            navigation.view.frame = window.bounds
            navigation.view.layoutIfNeeded()
            controller.tableView.scrollToRow(at: IndexPath(row: 2, section: 1), at: .bottom, animated: false)
            navigation.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: navigation.view.bounds).image { _ in
                navigation.view.drawHierarchy(in: navigation.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 20_000)
            let attachment = XCTAttachment(image: image)
            attachment.name = style == .light ? "external-push-light" : "external-push-dark"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }
}
