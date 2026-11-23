import UIKit

/// 邮箱多时用本地搜索选择，完整地址和复制操作保持可见，不为搜索请求接口。
final class SeekMailMailboxPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let mailboxes: [SeekMailbox]
    private let names: [Int64: SeekMailboxDisplay]
    private let counts: [Int64: Int]
    private let recentIDs: [Int64]
    private let selectedID: Int64?
    private let onSelect: (Int64?) -> Void
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let search = UISearchBar()
    private let scopeControl = UISegmentedControl(items: [SeekMailL10n.text("全部"), SeekMailL10n.text("未读"), SeekMailL10n.text("置顶邮箱")])
    private var groups: [(title: String?, rows: [Int64?])] = []
    private var keyboardDismissCoordinator: KeyboardDismissCoordinator?

    init(model: SeekMailInboxModel, onSelect: @escaping (Int64?) -> Void) {
        mailboxes = model.mailboxes
        names = model.names
        counts = model.unreadByMailbox
        recentIDs = model.selectionStore.recentMailboxIDs
        selectedID = model.selectedMailboxID
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        title = SeekMailL10n.text("选择邮箱")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        keyboardDismissCoordinator = KeyboardDismissCoordinator(rootView: view, backgrounds: [view, table])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        search.searchBarStyle = .minimal
        search.placeholder = SeekMailL10n.text("搜索邮箱名称或地址")
        search.searchTextField.accessibilityIdentifier = "seek-mail-picker-search"
        search.searchTextField.font = SeekMailFont.of(.body)
        search.delegate = self
        table.accessibilityIdentifier = "seek-mail-picker-list"
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 72
        scopeControl.selectedSegmentIndex = 0
        scopeControl.accessibilityIdentifier = "seek-mail-picker-scope"
        scopeControl.addAction(UIAction { [weak self] _ in
            guard let self, search.searchTextField.markedTextRange == nil else { return }
            update(query: search.text ?? "")
        }, for: .valueChanged)
        let scopeBar = UIStackView(arrangedSubviews: [scopeControl])
        scopeBar.isLayoutMarginsRelativeArrangement = true
        scopeBar.directionalLayoutMargins = .init(top: 0, leading: 16, bottom: 8, trailing: 16)
        let column = UIStackView(arrangedSubviews: [search, scopeBar, table])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        update(query: "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard searchBar.searchTextField.markedTextRange == nil else { return }
        update(query: searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        update(query: searchBar.text ?? "")
        searchBar.resignFirstResponder()
    }

    private func update(query: String) {
        let filtered = mailboxes.filter { mailbox in
            switch scopeControl.selectedSegmentIndex {
            case 1: (counts[mailbox.id] ?? 0) > 0
            case 2: mailbox.isPinned == true
            default: true
            }
        }
        let sections = SeekMailboxPickerSections.make(mailboxes: filtered, names: names, counts: counts, recentIDs: recentIDs, query: query)
        groups = sections.isSearching || scopeControl.selectedSegmentIndex != 0 ? [] : [(nil, [nil])]
        var included = Set<Int64>()
        for (title, rows) in [
            (SeekMailL10n.text("最近使用"), sections.recents),
            (SeekMailL10n.text("置顶邮箱"), sections.pinned),
            (SeekMailL10n.text("未读"), sections.unread),
            (SeekMailL10n.text("邮箱"), sections.others)
        ] {
            let ids = rows.map(\.mailboxID).filter { included.insert($0).inserted }
            if !ids.isEmpty { groups.append((title, ids.map(Optional.some))) }
        }
        if let background = table.backgroundView { keyboardDismissCoordinator?.unregister(background) }
        table.backgroundView = groups.isEmpty
            ? SeekMailStateView(message: SeekMailL10n.text("没有找到匹配的邮箱"), actionTitle: nil, action: nil) : nil
        if let background = table.backgroundView { keyboardDismissCoordinator?.register(background) }
        table.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = groups[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "mailbox") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "mailbox")
        cell.textLabel?.font = SeekMailFont.of(.body, weight: .medium)
        cell.detailTextLabel?.font = SeekMailFont.of(.footnote)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = id.flatMap { names[$0]?.title } ?? SeekMailL10n.text("全部邮箱")
        cell.detailTextLabel?.text = id.flatMap { names[$0]?.address } ?? SeekMailL10n.format("%@ 个邮箱", String(mailboxes.count))
        cell.imageView?.image = UIImage(systemName: id == selectedID ? "checkmark.circle.fill" : "envelope")
        cell.imageView?.tintColor = id == selectedID ? .label : .secondaryLabel
        cell.accessibilityIdentifier = id.map { "seek-mail-picker-row-\($0)" } ?? "seek-mail-picker-all"
        cell.accessibilityTraits = id == selectedID ? [.button, .selected] : .button
        let accessories = UIStackView()
        accessories.spacing = 6
        accessories.alignment = .center
        let unread = id.map { counts[$0] ?? 0 } ?? counts.values.reduce(0, +)
        if unread > 0 {
            let badge = UILabel()
            badge.text = unread > 99 ? "99+" : String(unread)
            badge.font = SeekMailFont.of(.footnote)
            badge.textColor = .secondaryLabel
            accessories.addArrangedSubview(badge)
        }
        if let id, let address = names[id]?.address {
            let copy = UIButton(type: .system)
            copy.tintColor = .label
            copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
            copy.accessibilityLabel = SeekMailL10n.text("复制地址")
            copy.accessibilityIdentifier = "seek-mail-picker-copy-\(id)"
            copy.addAction(UIAction { [weak self] _ in
                UIPasteboard.general.string = address
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.navigationItem.prompt = SeekMailL10n.format("已复制 %@", address)
            }, for: .touchUpInside)
            NSLayoutConstraint.activate([copy.widthAnchor.constraint(equalToConstant: 44), copy.heightAnchor.constraint(equalToConstant: 44)])
            accessories.addArrangedSubview(copy)
        }
        accessories.frame.size = accessories.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        cell.accessoryView = accessories.arrangedSubviews.isEmpty ? nil : accessories
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(groups[indexPath.section].rows[indexPath.row])
        dismiss(animated: true)
    }
}
