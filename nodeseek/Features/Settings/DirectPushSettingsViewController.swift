import UIKit

final class DirectPushSettingsViewController: UITableViewController {
    private let channel: DirectPushChannel
    private let store: DirectPushStoring
    private let sender: DirectPushSending
    private let accounts: CurrentAccountStore
    private let enabled = UISwitch()
    private let address = UITextField()
    private let group = UITextField()
    private let username = UITextField()
    private let password = UITextField()
    private var config: DirectPushConfiguration
    private var testTask: Task<Void, Never>?
    private var status: String?

    init(channel: DirectPushChannel, store: DirectPushStoring = DirectPushStore.shared,
         sender: DirectPushSending = DirectPushSender.shared, accounts: CurrentAccountStore = .shared) {
        self.channel = channel
        self.store = store
        self.sender = sender
        self.accounts = accounts
        config = store.configuration(channel) ?? DirectPushConfiguration(channel: channel)
        super.init(style: .insetGrouped)
        title = channel.title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { testTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        enabled.isOn = config.enabled
        address.placeholder = config.address.isEmpty ? (channel == .wecom ? "粘贴机器人的完整 Webhook" : "粘贴 Bark 中的完整推送地址") : "已保存，留空保持不变"
        group.text = config.group
        username.text = config.username
        password.placeholder = config.password.isEmpty ? "可选" : "已保存，留空保持不变"
        for field in [address, group, username, password] {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.font = .preferredFont(forTextStyle: .body)
        }
        address.isSecureTextEntry = true
        address.keyboardType = .URL
        address.accessibilityIdentifier = "direct-push-address"
        password.isSecureTextEntry = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save() })
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "direct-push-settings"
        status = UserDefaults.standard.string(forKey: DirectPushMonitor.statusKey(channel))
    }

    override func numberOfSections(in tableView: UITableView) -> Int { channel == .bark ? 4 : 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 2 }
        if channel == .bark && section == 1 { return 4 }
        return section == (channel == .bark ? 2 : 1) ? 2 : 1
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "直接连接" }
        if channel == .bark && section == 1 { return "Bark 选项" }
        return nil
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return "无需部署通知服务或绑定 Telegram。密钥只保存在本机 Keychain。自动转发绑定当前 NodeSeek 账号，首次开启仅记录已有通知。切换账号后请重新保存配置。"
        }
        if section == (channel == .bark ? 2 : 1) { return status ?? "测试通知直接发送到所选渠道，无需登录 NodeSeek。" }
        if section == (channel == .bark ? 3 : 2) {
            return "App 运行时定期检查新通知；后台刷新由 iOS 调度，不保证实时。强制关闭 App 后不会继续转发。"
        }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.textColor = .label
        if indexPath.section == 0 {
            if indexPath.row == 0 { cell.textLabel?.text = "自动转发新通知"; cell.accessoryView = enabled }
            else { field(address, in: cell, title: channel == .wecom ? "Webhook" : "推送地址") }
        } else if channel == .bark && indexPath.section == 1 {
            switch indexPath.row {
            case 0: field(group, in: cell, title: "分组")
            case 1: cell.textLabel?.text = "提醒方式"; cell.detailTextLabel?.text = levelTitle; cell.accessoryType = .disclosureIndicator
            case 2: field(username, in: cell, title: "鉴权用户名")
            default: field(password, in: cell, title: "鉴权密码")
            }
        } else if indexPath.section == (channel == .bark ? 2 : 1) {
            cell.textLabel?.text = indexPath.row == 0 ? "发送测试通知" : "立即检查新通知"
            cell.textLabel?.textColor = .systemBlue
            cell.accessibilityIdentifier = indexPath.row == 0 ? "direct-push-test" : "direct-push-check"
        } else {
            cell.textLabel?.text = "清除配置"
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    private var levelTitle: String { ["active": "普通通知", "passive": "静默通知", "timeSensitive": "时效性通知"][config.level] ?? "普通通知" }
    private func field(_ field: UITextField, in cell: UITableViewCell, title: String) {
        cell.textLabel?.text = title
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 120),
            field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12), field.heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
    }

    private func edited() throws -> DirectPushConfiguration {
        var next = config
        let raw = address.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { next.address = raw }
        next.enabled = enabled.isOn
        next.group = group.text?.isEmpty == false ? group.text! : "NodeSeek"
        next.username = username.text ?? ""
        if let value = password.text, !value.isEmpty { next.password = value }
        if next.username.isEmpty { next.password = "" }
        _ = try next.validatedURL()
        return next
    }

    private func save() {
        guard testTask == nil else { return }
        testTask = Task { [weak self] in
            guard let self else { return }
            defer { testTask = nil }
            do {
                var next = try edited()
                let account = await accounts.snapshot()?.account
                if next.enabled {
                    guard account?.isLoggedIn == true, let uid = account?.nodeSeekUID else { throw DirectPushError.loginRequired }
                    next.accountID = uid
                }
                if next.address != config.address || next.accountID != config.accountID || (next.enabled && !config.enabled) {
                    next.revision = UUID()
                }
                try store.save(next)
                config = next
                address.text = nil; password.text = nil
                address.placeholder = "已保存，留空保持不变"
                status = next.enabled ? "已保存，下一次检查会记录基线，之后转发新通知" : "已保存，自动转发关闭，可发送测试通知"
                tableView.reloadData()
            } catch { show(error) }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if channel == .bark && indexPath.section == 1 && indexPath.row == 1 {
            let sheet = UIAlertController(title: "提醒方式", message: nil, preferredStyle: .actionSheet)
            for (value, title) in [("active", "普通通知"), ("passive", "静默通知"), ("timeSensitive", "时效性通知")] {
                sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.config.level = value; self?.tableView.reloadData() })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
            present(sheet, animated: true)
        } else if indexPath.section == (channel == .bark ? 2 : 1) {
            if indexPath.row == 0 { test() }
            else {
                guard testTask == nil else { return }
                testTask = Task { [weak self] in
                    await DirectPushMonitor.shared.check()
                    self?.testTask = nil
                    self?.status = UserDefaults.standard.string(forKey: DirectPushMonitor.statusKey(self?.channel ?? .bark)) ?? "检查已完成；首次开启仅建立基线"
                    self?.tableView.reloadData()
                }
            }
        } else if indexPath.section == (channel == .bark ? 3 : 2) {
            let alert = UIAlertController(title: "清除渠道配置？", message: "仅清除本机密钥与自动转发设置。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
                guard let self else { return }
                do { try store.remove(channel); navigationController?.popViewController(animated: true) }
                catch { show(error) }
            })
            present(alert, animated: true)
        }
    }

    private func test() {
        guard testTask == nil || testTask?.isCancelled == true else { return }
        do {
            let next = try edited()
            status = "正在发送测试通知…"; tableView.reloadData()
            testTask = Task { [weak self] in
                guard let self else { return }
                defer { testTask = nil }
                do {
                    try await sender.send(DirectPushEvent(id: "test-\(UUID())", title: "NS Connect 测试通知", body: "此通知由 App 直接发送。", type: "message", url: nil, date: Date()), configuration: next)
                    status = "测试通知已提交，请在对应应用确认收件"
                } catch { status = error.localizedDescription }
                tableView.reloadData()
            }
        } catch { show(error) }
    }
    private func show(_ error: Error) {
        status = (error as? DirectPushError)?.localizedDescription ?? "操作失败，请重试"
        tableView.reloadData()
    }
}
