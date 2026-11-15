import UIKit
import UserNotifications

enum PushNotificationSettingsCopy {
    static let nsApnsRepositoryURL = URL(string: "https://github.com/nnnmdzz/ns-apns")!
    static let setupSteps = """
    1. 选择企业微信机器人或 Bark，粘贴对应的推送地址
    2. 保存配置，发送测试通知确认连接
    3. 登录 NodeSeek 后开启自动转发，无需另行部署服务
    """

    static func listSummary(for status: UNAuthorizationStatus, directConfigured: Bool = false) -> String {
        if directConfigured { return "已配置直连渠道" }
        switch status {
        case .notDetermined:
            return "未开启"
        case .denied:
            return "系统已关闭"
        case .authorized, .provisional, .ephemeral:
            return "已开启"
        @unknown default:
            return "未开启"
        }
    }

    static func statusText(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "尚未开启"
        case .denied:
            return "已关闭"
        case .authorized:
            return "已开启"
        case .provisional, .ephemeral:
            return "临时开启"
        @unknown default:
            return "未知"
        }
    }
}

/// 设置里的推送入口：点开才申请权限，并提供复制 device token。
final class PushNotificationSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case steps
        case inApp
        case channels
        case permission
        case token
        case nsApns
    }

    private enum PermissionRow: Int, CaseIterable {
        case status
        case enable
        case systemSettings
    }

    private enum TokenRow: Int, CaseIterable {
        case value
        case fetch
        case copy
    }

    private enum NsApnsRow: Int, CaseIterable {
        case github
    }

    private let messageCenter: AppMessageCenter
    private let directStore: DirectPushStoring
    private let tokenStore: PushNotificationTokenStore
    private let notificationCenter: UNUserNotificationCenter
    private let application: UIApplication
    private let authorizationStatusProvider: @MainActor () async -> UNAuthorizationStatus
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(
        tokenStore: PushNotificationTokenStore = .shared,
        messageCenter: AppMessageCenter? = nil,
        directStore: DirectPushStoring = DirectPushStore.shared,
        notificationCenter: UNUserNotificationCenter = .current(),
        application: UIApplication = .shared,
        authorizationStatusProvider: @escaping @MainActor () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    ) {
        self.messageCenter = messageCenter ?? .shared
        self.directStore = directStore
        self.tokenStore = tokenStore
        self.notificationCenter = notificationCenter
        self.application = application
        self.authorizationStatusProvider = authorizationStatusProvider
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = UIColor.systemGroupedBackground
        title = "推送通知"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.accessibilityIdentifier = "push-notification-settings-table-view"
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tokenDidChange),
            name: PushNotificationTokenStore.didChangeNotification,
            object: tokenStore
        )
        refreshAuthorizationStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshAuthorizationStatus()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .steps, .inApp:
            return 1
        case .permission:
            return visiblePermissionRows().count
        case .token:
            return TokenRow.allCases.count
        case .nsApns:
            return NsApnsRow.allCases.count
        case .channels:
            return 2
        case .none:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .steps:
            return "使用步骤"
        case .inApp:
            return "消息提醒"
        case .permission:
            return "App 推送 · 系统权限"
        case .token:
            return "Device Token"
        case .nsApns:
            return "原有 App 推送（可选）"
        case .channels:
            return "其他通知渠道"
        case .none:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .steps:
            return nil
        case .inApp:
            return "所有页面右上角均可打开消息。前台约每 20 秒检查一次，显示未读角标与可点击提醒；关闭提醒仍保留消息入口。后台通知需开启系统权限，刷新时间由 iOS 决定，强制关闭 App 后不继续检查。"
        case .permission:
            return "不会在打开本页时弹窗，只有点「开启通知」才会向系统申请。"
        case .token:
            return "复制后粘贴到 ns-apns 设置页的 Device Token。换机或重装后需要重新获取。"
        case .nsApns:
            return "仅原有 APNs 方式使用 ns-apns；企业微信与 Bark 直接连接，不需要此服务或 Device Token。"
        case .channels:
            return "直接连接所选服务，密钥仅保存在本机。App 运行时检查通知，后台刷新由 iOS 调度；强制关闭后不继续转发。"
        case .none:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .steps:
            return stepsCell()
        case .inApp:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "新消息提醒"
            let toggle = UISwitch()
            toggle.isOn = messageCenter.alertsEnabled
            toggle.accessibilityIdentifier = "app-message-alerts-switch"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                messageCenter.alertsEnabled = toggle.isOn
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell
        case .permission:
            return permissionCell(for: visiblePermissionRows()[indexPath.row])
        case .token:
            return tokenCell(for: TokenRow(rawValue: indexPath.row))
        case .nsApns:
            return nsApnsCell(for: NsApnsRow(rawValue: indexPath.row))
        case .channels:
            return channelCell(row: indexPath.row)
        case .none:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .steps, .inApp:
            break
        case .permission:
            switch visiblePermissionRows()[indexPath.row] {
            case .enable:
                requestAuthorizationThenRegister()
            case .systemSettings:
                openSystemSettings()
            case .status:
                break
            }
        case .token:
            switch TokenRow(rawValue: indexPath.row) {
            case .fetch:
                fetchToken()
            case .copy:
                copyToken()
            case .value, .none:
                break
            }
        case .channels:
            openChannel(indexPath.row == 0 ? .wecom : .bark)
        case .nsApns:
            switch NsApnsRow(rawValue: indexPath.row) {
            case .github:
                openNsApnsRepository()
            case .none:
                break
            }
        case .none:
            break
        }
    }

    private func visiblePermissionRows() -> [PermissionRow] {
        var rows: [PermissionRow] = [.status]
        switch authorizationStatus {
        case .denied:
            rows.append(.systemSettings)
        case .authorized, .provisional, .ephemeral:
            break
        default:
            rows.append(.enable)
        }
        return rows
    }

    private func stepsCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.textColor = ReadingColors.text
        cell.textLabel?.text = PushNotificationSettingsCopy.setupSteps
        cell.textLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "push-notification-setup-steps-cell"

        return cell
    }

    private func permissionCell(for row: PermissionRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.textColor = ReadingColors.text
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        switch row {
        case .status:
            cell.textLabel?.text = "当前状态"
            cell.detailTextLabel?.text = statusText
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "push-notification-status-cell"
        case .enable:
            cell.textLabel?.text = "开启通知"
            cell.detailTextLabel?.text = "允许显示横幅、声音和标记"
            cell.imageView?.image = UIImage(systemName: "bell.badge")
            cell.accessibilityIdentifier = "push-notification-enable-cell"
        case .systemSettings:
            cell.textLabel?.text = "前往系统设置"
            cell.detailTextLabel?.text = "通知已被关闭，需要在系统设置中重新打开"
            cell.imageView?.image = UIImage(systemName: "gear")
            cell.accessibilityIdentifier = "push-notification-system-settings-cell"
        }

        return cell
    }

    private func tokenCell(for row: TokenRow?) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.textColor = ReadingColors.text
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        switch row {
        case .value:
            cell.textLabel?.text = "当前 Token"
            if let hex = tokenStore.deviceTokenHex {
                cell.detailTextLabel?.text = hex
            } else if let error = tokenStore.lastError {
                cell.detailTextLabel?.text = "获取失败：\(error)"
            } else {
                cell.detailTextLabel?.text = "还没有，请先开启通知"
            }
            cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "push-notification-token-value-cell"
        case .fetch:
            cell.textLabel?.text = "获取 Token"
            cell.detailTextLabel?.text = "注册本机，成功后显示在上方"
            cell.imageView?.image = UIImage(systemName: "arrow.down.circle")
            cell.accessibilityIdentifier = "push-notification-fetch-token-cell"
        case .copy:
            let hasToken = tokenStore.deviceTokenHex != nil
            cell.textLabel?.text = "复制 Token"
            cell.detailTextLabel?.text = hasToken ? "复制到剪贴板" : "还没有可复制的内容"
            cell.imageView?.image = UIImage(systemName: "doc.on.doc")
            cell.selectionStyle = hasToken ? .default : .none
            cell.isUserInteractionEnabled = hasToken
            cell.accessibilityIdentifier = "push-notification-copy-token-cell"
        case .none:
            break
        }

        return cell
    }

    private func nsApnsCell(for row: NsApnsRow?) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.textColor = ReadingColors.text
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2
        switch row {
        case .github:
            cell.textLabel?.text = "GitHub"
            cell.detailTextLabel?.text = PushNotificationSettingsCopy.nsApnsRepositoryURL.absoluteString
            cell.imageView?.image = UIImage(systemName: "link")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "push-notification-ns-apns-github-cell"
        case .none:
            break
        }

        return cell
    }


    private func channelCell(row: Int) -> UITableViewCell {
        let channel: DirectPushChannel = row == 0 ? .wecom : .bark
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = channel.title
        let saved = directStore.configuration(channel)
        cell.detailTextLabel?.text = saved.map { $0.enabled ? "已开启自动转发 · 直接连接" : "已配置 · 自动转发关闭" }
            ?? (channel == .wecom ? "直接填写机器人 Webhook，无需部署服务" : "直接填写 Bark 地址，支持官方与自架服务")
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = UIImage(systemName: channel == .wecom ? "bubble.left.and.bubble.right" : "bell.badge")
        cell.accessibilityIdentifier = "push-channel-\(channel.rawValue)"
        return cell
    }

    private func openChannel(_ channel: DirectPushChannel) {
        navigationController?.pushViewController(DirectPushSettingsViewController(channel: channel, store: directStore), animated: true)
    }

    private var statusText: String {
        PushNotificationSettingsCopy.statusText(for: authorizationStatus)
    }

    private func refreshAuthorizationStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            authorizationStatus = await authorizationStatusProvider()
            tableView.reloadData()
        }
    }

    private func requestAuthorizationThenRegister(registerRemote: Bool = false) {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshAuthorizationStatus()
                if granted && registerRemote {
                    self?.application.registerForRemoteNotifications()
                }
            }
        }
    }

    private func fetchToken() {
        switch authorizationStatus {
        case .notDetermined:
            requestAuthorizationThenRegister(registerRemote: true)
        case .denied:
            openSystemSettings()
        default:
            application.registerForRemoteNotifications()
        }
    }

    private func copyToken() {
        guard let token = tokenStore.deviceTokenHex else { return }
        UIPasteboard.general.string = token
        let alert = UIAlertController(title: "已复制", message: "去 ns-apns 设置页粘贴即可。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func openNsApnsRepository() {
        application.open(PushNotificationSettingsCopy.nsApnsRepositoryURL)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        application.open(url)
    }

    @objc private func tokenDidChange() {
        tableView.reloadSections(IndexSet(integer: Section.token.rawValue), with: .none)
    }

    func applyAuthorizationStatusForTesting(_ status: UNAuthorizationStatus) {
        authorizationStatus = status
        tableView.reloadData()
    }
}
