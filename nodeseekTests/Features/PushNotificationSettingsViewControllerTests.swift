import Testing
import UIKit
import UserNotifications
@testable import nodeseek

@MainActor
struct PushNotificationSettingsViewControllerTests {
    @Test func screenShowsPermissionTokenAndNsApnsSections() throws {
        let viewController = makeViewController(authorizationStatus: .notDetermined)
        viewController.loadViewIfNeeded()

        #expect(viewController.title == "推送通知")
        #expect(viewController.tableView.numberOfSections == 5)
        #expect(viewController.tableView.numberOfRows(inSection: 0) == 1)
        #expect(viewController.tableView.numberOfRows(inSection: 2) == 2)
        #expect(viewController.tableView.numberOfRows(inSection: 3) == 3)
        #expect(viewController.tableView.numberOfRows(inSection: 4) == 1)
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForHeaderInSection: 0
        ) == "使用步骤")
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForHeaderInSection: 2
        ) == "App 推送 · 系统权限")
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForHeaderInSection: 3
        ) == "Device Token")
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForHeaderInSection: 4
        ) == "原有 App 推送（可选）")
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForFooterInSection: 2
        ) == "不会在打开本页时弹窗，只有点「开启通知」才会向系统申请。")
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForFooterInSection: 3
        ) == "复制后粘贴到 ns-apns 设置页的 Device Token。换机或重装后需要重新获取。")
        #expect(viewController.tableView.dataSource?.tableView?(
            viewController.tableView,
            titleForFooterInSection: 4
        ) == "仅原有 APNs 方式使用 ns-apns；企业微信与 Bark 直接连接，不需要此服务或 Device Token。")

        let stepsCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0)
        ))
        let statusCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        ))
        let enableCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 1, section: 2)
        ))
        let tokenCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 3)
        ))
        let fetchCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 1, section: 3)
        ))
        let copyCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 2, section: 3)
        ))
        let githubCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 4)
        ))

        #expect(stepsCell.textLabel?.text == PushNotificationSettingsCopy.setupSteps)
        #expect(stepsCell.selectionStyle == .none)
        #expect(statusCell.textLabel?.text == "当前状态")
        #expect(statusCell.detailTextLabel?.text == "尚未开启")
        #expect(enableCell.textLabel?.text == "开启通知")
        #expect(enableCell.detailTextLabel?.text == "允许显示横幅、声音和标记")
        #expect(tokenCell.textLabel?.text == "当前 Token")
        #expect(tokenCell.detailTextLabel?.text == "还没有，请先开启通知")
        #expect(fetchCell.textLabel?.text == "获取 Token")
        #expect(fetchCell.detailTextLabel?.text == "注册本机，成功后显示在上方")
        #expect(copyCell.textLabel?.text == "复制 Token")
        #expect(copyCell.detailTextLabel?.text == "还没有可复制的内容")
        #expect(githubCell.textLabel?.text == "GitHub")
        #expect(githubCell.detailTextLabel?.text == "https://github.com/nnnmdzz/ns-apns")
        #expect(githubCell.accessoryType == .disclosureIndicator)
    }

    @Test func deniedStatusReplacesEnableRowWithSystemSettings() throws {
        let viewController = makeViewController(authorizationStatus: .denied)
        viewController.loadViewIfNeeded()
        viewController.applyAuthorizationStatusForTesting(.denied)

        #expect(viewController.tableView.numberOfRows(inSection: 2) == 2)
        let statusCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 0, section: 2)
        ))
        let settingsCell = try #require(viewController.tableView.dataSource?.tableView(
            viewController.tableView,
            cellForRowAt: IndexPath(row: 1, section: 2)
        ))
        #expect(statusCell.detailTextLabel?.text == "已关闭")
        #expect(settingsCell.textLabel?.text == "前往系统设置")
        #expect(settingsCell.detailTextLabel?.text == "通知已被关闭，需要在系统设置中重新打开")
    }

    @Test func copyMappingUsesShortStatusForListAndDetail() {
        #expect(PushNotificationSettingsCopy.listSummary(for: .notDetermined) == "未开启")
        #expect(PushNotificationSettingsCopy.listSummary(for: .denied) == "系统已关闭")
        #expect(PushNotificationSettingsCopy.listSummary(for: .authorized) == "已开启")
        #expect(PushNotificationSettingsCopy.listSummary(for: .provisional) == "已开启")
        #expect(PushNotificationSettingsCopy.statusText(for: .notDetermined) == "尚未开启")
        #expect(PushNotificationSettingsCopy.statusText(for: .denied) == "已关闭")
        #expect(PushNotificationSettingsCopy.statusText(for: .authorized) == "已开启")
        #expect(PushNotificationSettingsCopy.statusText(for: .provisional) == "临时开启")
        #expect(PushNotificationSettingsCopy.statusText(for: .ephemeral) == "临时开启")
        #expect(PushNotificationSettingsCopy.nsApnsRepositoryURL.absoluteString == "https://github.com/nnnmdzz/ns-apns")
        #expect(PushNotificationSettingsCopy.setupSteps.contains("无需另行部署服务"))
        #expect(PushNotificationSettingsCopy.setupSteps.contains("企业微信机器人或 Bark"))
        #expect(PushNotificationSettingsCopy.setupSteps.contains("发送测试通知"))
    }
}

@MainActor
private func makeViewController(
    authorizationStatus: UNAuthorizationStatus
) -> PushNotificationSettingsViewController {
    let suiteName = "push-notification-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return PushNotificationSettingsViewController(
        tokenStore: PushNotificationTokenStore(defaults: defaults),
        authorizationStatusProvider: { authorizationStatus }
    )
}
