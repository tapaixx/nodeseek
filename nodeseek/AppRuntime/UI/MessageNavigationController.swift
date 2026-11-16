import UIKit

enum MessageShortcutPolicy {
    static func hasExistingEntry(in controller: UIViewController?) -> Bool {
        if let tabs = controller as? MainTabBarController {
            if !tabs.tabBar.isHidden, tabs.tabItems.contains(.notification) { return true }
            return hasExistingEntry(in: tabs.selectedViewController)
        }
        if let home = controller as? PostListViewController {
            // 阅读模式通过侧边栏进入通知，多 Tab 模式取决于底栏是否保留通知。
            return home.layout == .reading
        }
        return controller is NotificationViewController || controller is PostListSideMenuViewController
    }
}

/// 所有 App 自有導覽棧共用，保留各頁原有第一個右側按鈕的語意。
final class MessageNavigationController: UINavigationController {
    private let messageCenter: AppMessageCenter
    init(rootViewController: UIViewController, messageCenter: AppMessageCenter? = nil) {
        let messageCenter = messageCenter ?? .shared
        self.messageCenter = messageCenter
        super.init(navigationBarClass: MessageNavigationBar.self, toolbarClass: nil)
        if let bar = navigationBar as? MessageNavigationBar { bar.owner = self; bar.messageCenter = messageCenter }
        setViewControllers([rootViewController], animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setNavigationBarHidden(_ hidden: Bool, animated: Bool) {
        super.setNavigationBarHidden(hidden, animated: animated)
        DispatchQueue.main.async { [weak self] in self?.messageCenter.updatePresentation() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (navigationBar as? MessageNavigationBar)?.updateShortcut()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (navigationBar as? MessageNavigationBar)?.updateShortcut()
        messageCenter.updatePresentation()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.main.async { [weak self] in self?.messageCenter.updatePresentation() }
    }
}

final class MessageNavigationBar: UINavigationBar {
    static let shortcutID = "global-message-shortcut"
    private weak var observedItem: UINavigationItem?
    private var observations: [NSKeyValueObservation] = []
    private var installing = false
    weak var owner: UINavigationController?
    var messageCenter: AppMessageCenter = .shared
    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(messageStateChanged), name: AppMessageCenter.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func messageStateChanged() { setNeedsLayout() }
    override func layoutSubviews() {
        updateShortcut()
        super.layoutSubviews()
    }
    func updateShortcut() {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        if let item = topItem {
            if observedItem !== item {
                observedItem = item
                // UIKit 可直接更新導覽列內容而不再排版 bar；監聽頁面重設按鈕的兩種入口。
                observations = [
                    item.observe(\.rightBarButtonItems) { [weak self] _, _ in
                        DispatchQueue.main.async { [weak self] in self?.updateShortcut() }
                    },
                    item.observe(\.rightBarButtonItem) { [weak self] _, _ in
                        DispatchQueue.main.async { [weak self] in self?.updateShortcut() }
                    }
                ]
            }
            var buttons = item.rightBarButtonItems ?? []
            if MessageShortcutPolicy.hasExistingEntry(in: owner?.topViewController) {
                if buttons.contains(where: { $0.accessibilityIdentifier == Self.shortcutID }) {
                    buttons.removeAll { $0.accessibilityIdentifier == Self.shortcutID }
                    item.rightBarButtonItems = buttons
                }
                return
            }
            let shortcut = buttons.first { $0.accessibilityIdentifier == Self.shortcutID }
            let control: MessageShortcutButton
            if let existing = shortcut?.customView as? MessageShortcutButton { control = existing }
            else {
                control = MessageShortcutButton(frame: .zero)
                let entry = UIBarButtonItem(customView: control)
                entry.accessibilityIdentifier = Self.shortcutID
                if #available(iOS 26.0, *) { entry.hidesSharedBackground = true }
                buttons.removeAll { $0.accessibilityIdentifier == Self.shortcutID }
                buttons.append(entry)
                item.rightBarButtonItems = buttons
            }
            control.update(count: messageCenter.unreadCount.all)
            control.onTap = { [weak self] in
                guard let self, let owner else { return }
                messageCenter.openMessages(in: owner)
            }
        }
    }
}

final class MessageShortcutButton: UIControl {
    var onTap: (() -> Void)?
    private let badge = UIImageView()
    private var renderedCount: Int?
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 圖示與角標分開保留，不讓導覽列套用單色文字效果。
        let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        isAccessibilityElement = true
        accessibilityTraits = .button
        badge.accessibilityIdentifier = "message-unread-badge"
        badge.isUserInteractionEnabled = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 27), icon.heightAnchor.constraint(equalToConstant: 24),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 1), badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 15), badge.heightAnchor.constraint(equalToConstant: 16)
        ])
        accessibilityIdentifier = MessageNavigationBar.shortcutID
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        update(count: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(count: Int) {
        if renderedCount != count {
            renderedCount = count
            let text = count > 99 ? "99+" : "\(max(0, count))"
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: UIColor.white]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let size = CGSize(width: max(16, ceil(textSize.width) + 6), height: 16)
            // UIBarButtonItem 會對 UILabel 套用單色外觀；原色圖片讓背景與數字保持可辨識。
            badge.image = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.systemRed.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()
                (text as NSString).draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
            }.withRenderingMode(.alwaysOriginal)
        }
        badge.isHidden = count <= 0
        accessibilityLabel = count > 0 ? "消息，\(count) 条未读" : "打开消息"
        accessibilityValue = count > 0 ? "\(count)" : "0"
    }
}
