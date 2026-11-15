import UIKit
import UserNotifications
import SafariServices

enum PushNotificationSettingsCopy {
    static let nsApnsRepositoryURL = URL(string: "https://github.com/nnnmdzz/ns-apns")!
    static let setupSteps = """
    1. 在 NodeSeek 绑定官方 Telegram「新提醒」
    2. 自行部署 ns-apns，在服务中完成登录
    3. 选择 App 推送、企业微信机器人或 Bark，可同时启用
    """

    static func listSummary(for status: UNAuthorizationStatus, relayConfigured: Bool = false) -> String {
        if relayConfigured { return "已配置推送服务" }
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

    private let relayStore: PushRelaySettingsStore
    private let openRelay: ((URL) -> Void)?
    private let tokenStore: PushNotificationTokenStore
    private let notificationCenter: UNUserNotificationCenter
    private let application: UIApplication
    private let authorizationStatusProvider: @MainActor () async -> UNAuthorizationStatus
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(
        tokenStore: PushNotificationTokenStore = .shared,
        relayStore: PushRelaySettingsStore = .shared,
        openRelay: ((URL) -> Void)? = nil,
        notificationCenter: UNUserNotificationCenter = .current(),
        application: UIApplication = .shared,
        authorizationStatusProvider: @escaping @MainActor () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    ) {
        self.relayStore = relayStore
        self.openRelay = openRelay
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
        case .steps:
            return 1
        case .permission:
            return visiblePermissionRows().count
        case .token:
            return TokenRow.allCases.count
        case .nsApns:
            return NsApnsRow.allCases.count
        case .channels:
            return 3
        case .none:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .steps:
            return "使用步骤"
        case .permission:
            return "App 推送 · 系统权限"
        case .token:
            return "Device Token"
        case .nsApns:
            return "部署与维护"
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
        case .permission:
            return "不会在打开本页时弹窗，只有点「开启通知」才会向系统申请。"
        case .token:
            return "复制后粘贴到 ns-apns 设置页的 Device Token。换机或重装后需要重新获取。"
        case .nsApns:
            return "在 ns-apns 中维护登录状态与通知渠道。仅 App 推送需要填写 Device Token。"
        case .channels:
            return "企业微信与 Bark 由常驻服务转发，App 关闭后仍可接收，无需 Device Token。密钥仅在服务设置页维护。"
        case .none:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .steps:
            return stepsCell()
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
        case .steps:
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
            if indexPath.row == 0 { editRelayAddress() }
            else { openChannel(indexPath.row == 1 ? "wecom" : "bark") }
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
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        cell.textLabel?.text = ["推送服务地址", "企业微信机器人", "Bark"][row]
        cell.detailTextLabel?.text = row == 0
            ? (relayStore.baseURL?.absoluteString ?? "填写已部署的 ns-apns 地址")
            : (row == 1 ? "配置 Webhook、启用或停用、发送测试通知" : "支持官方与自架服务，点击通知可回到 App")
        cell.imageView?.image = UIImage(systemName: ["server.rack", "bubble.left.and.bubble.right", "bell.badge"][row])
        cell.accessibilityIdentifier = ["push-relay-address", "push-channel-wecom", "push-channel-bark"][row]
        return cell
    }

    private func editRelayAddress(channel: String? = nil) {
        let alert = UIAlertController(title: "推送服务地址", message: "填写已部署的 ns-apns HTTPS 地址。Webhook 和 Bark 推送地址请在对应渠道页面填写。", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "https://notify.example.com"
            $0.text = self.relayStore.baseURL?.absoluteString
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.accessibilityIdentifier = "push-relay-address-input"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard raw.isEmpty || PushRelayAddress.normalized(raw) != nil else {
                let error = UIAlertController(title: "地址格式有误", message: "请输入不含账号密码、路径或密钥的 HTTPS 服务地址。", preferredStyle: .alert)
                error.addAction(UIAlertAction(title: "重新填写", style: .default) { [weak self] _ in self?.editRelayAddress(channel: channel) })
                error.addAction(UIAlertAction(title: "取消", style: .cancel))
                self.present(error, animated: true)
                return
            }
            self.relayStore.save(PushRelayAddress.normalized(raw))
            self.tableView.reloadSections(IndexSet(integer: Section.channels.rawValue), with: .none)
            if let channel, !raw.isEmpty { self.openChannel(channel) }
        })
        present(alert, animated: true)
    }

    private func openChannel(_ channel: String) {
        guard let base = relayStore.baseURL,
              let url = PushRelayAddress.settingsURL(base: base, channel: channel) else {
            editRelayAddress(channel: channel)
            return
        }
        if let openRelay { openRelay(url) }
        else { present(SFSafariViewController(url: url), animated: true) }
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

    private func requestAuthorizationThenRegister() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshAuthorizationStatus()
                if granted {
                    self?.application.registerForRemoteNotifications()
                }
            }
        }
    }

    private func fetchToken() {
        switch authorizationStatus {
        case .notDetermined:
            requestAuthorizationThenRegister()
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
