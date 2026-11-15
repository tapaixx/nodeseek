import UIKit

@MainActor
final class MessageConversationViewController: UIViewController, UITableViewDataSource, UITextViewDelegate {
    let model: MessageConversationViewModel
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let input = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let confirmRetryButton = UIButton(type: .system)
    private let refreshControl = UIRefreshControl()
    private let participantHeader = MessageParticipantHeaderView()
    private var inputHeight: NSLayoutConstraint!
    private var refreshTask: Task<Void, Never>?
    private var renderedMessages: [NodeSeekDirectMessage] = []

    init(
        participantID: Int,
        participantName: String = "私信",
        client: NodeSeekMessageClientProtocol? = nil,
        currentAccountStore: CurrentAccountStore = .shared,
        profileClient: MessageParticipantLoading? = nil
    ) {
        model = MessageConversationViewModel(
            participantID: participantID, participantName: participantName,
            client: client ?? NodeSeekMessageClient(), currentAccountStore: currentAccountStore,
            profileClient: profileClient ?? NodeSeekUserContentClient()
        )
        super.init(nibName: nil, bundle: nil)
        title = participantName
        hidesBottomBarWhenPushed = true
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { refreshTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        model.onChange = { [weak self] in self?.render() }
        render()
        Task { [weak self] in await self?.model.load() }
        Task { [weak self] in await self?.model.loadParticipant() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if UIApplication.shared.applicationState == .active { await model.load() }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func configureUI() {
        view.backgroundColor = .systemGroupedBackground
        tableView.backgroundColor = .clear
        participantHeader.profileButton.addAction(UIAction { [weak self] _ in self?.openProfile() }, for: .touchUpInside)
        participantHeader.onExpansionChanged = { [weak self] in
            guard let self else { return }
            let nearBottom = tableView.contentSize.height - tableView.contentOffset.y - tableView.bounds.height < 120
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.view.layoutIfNeeded()
                if nearBottom, !self.renderedMessages.isEmpty {
                    self.tableView.scrollToRow(at: IndexPath(row: self.renderedMessages.count - 1, section: 0), at: .bottom, animated: false)
                }
            }
        }
        participantHeader.postButton.addAction(UIAction { [weak self] _ in self?.openLatestPost() }, for: .touchUpInside)
        tableView.accessibilityIdentifier = "message-conversation-table"
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.allowsSelection = false
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.register(MessageBubbleCell.self, forCellReuseIdentifier: "message")
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "message-conversation-status"
        retryButton.setTitle("刷新对话", for: .normal)
        retryButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        confirmRetryButton.setTitle("已核对，允许重新发送", for: .normal)
        confirmRetryButton.addTarget(self, action: #selector(confirmRetry), for: .touchUpInside)
        let status = UIStackView(arrangedSubviews: [statusLabel, retryButton, confirmRetryButton])
        status.axis = .vertical
        status.alignment = .leading
        status.spacing = 4

        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.backgroundColor = .secondarySystemGroupedBackground
        input.textColor = .label
        input.layer.cornerRadius = 12
        input.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        input.delegate = self
        input.accessibilityLabel = "私信内容"
        input.accessibilityIdentifier = "message-conversation-input"
        placeholder.text = "输入私信…"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 13),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 10)
        ])
        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        sendButton.accessibilityIdentifier = "message-conversation-send"
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        let composer = UIStackView(arrangedSubviews: [input, sendButton])
        composer.alignment = .bottom
        composer.spacing = 10

        inputHeight = input.heightAnchor.constraint(equalToConstant: 44)
        [participantHeader, status, tableView, composer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            participantHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            participantHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            participantHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.topAnchor.constraint(equalTo: participantHeader.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            inputHeight,
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        let browser = UIAction(title: "在网页中打开", image: UIImage(systemName: "globe")) { [weak self] _ in
            guard let self else { return }
            navigationController?.pushViewController(
                NodeSeekWebViewController(url: NodeSeekMessageClient.webURL(participantID: model.participantID)), animated: true
            )
        }
        let profile = UIAction(title: "查看对方主页", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in self?.openProfile() }
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)), for: .normal)
        more.tintColor = .label
        more.menu = UIMenu(children: [profile, browser])
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "聊天更多操作"
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 44), more.heightAnchor.constraint(equalToConstant: 44)])
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: more)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeInput()
    }

    private func resizeInput() {
        guard input.bounds.width > 0 else { return }
        let measured = input.sizeThatFits(CGSize(width: input.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(120, max(44, ceil(measured)))
        input.isScrollEnabled = measured > 120
        if abs(inputHeight.constant - height) > 0.5 { inputHeight.constant = height }
    }

    private func openProfile(uid: Int? = nil) {
        navigationController?.pushViewController(UserProfileViewController(uid: uid ?? model.participantID), animated: true)
    }

    private func openLatestPost() {
        guard let post = model.latestDiscussion else { return }
        navigationController?.pushViewController(PostDetailRouter.createModule(
            post: UserContentPostSummaryFactory.postSummary(id: post.postID, title: post.title)
        ), animated: true)
    }

    private func render() {
        title = model.participantName
        participantHeader.configure(uid: model.participantID, name: model.participantName,
                                    profile: model.participantProfile, post: model.latestDiscussion)
        statusLabel.text = model.errorMessage ?? (model.isLoading && !model.hasLoaded ? "正在加载私信…" : nil)
        statusLabel.isHidden = statusLabel.text == nil
        retryButton.isHidden = model.errorMessage == nil
        retryButton.isEnabled = !model.isLoading && !model.isSending
        confirmRetryButton.isHidden = !model.deliveryUncertain
        input.isEditable = !model.isSending
        if input.text != model.draft { input.text = model.draft }
        placeholder.isHidden = !model.draft.isEmpty
        resizeInput()
        sendButton.setTitle(model.isSending ? "发送中…" : "发送", for: .normal)
        sendButton.isEnabled = model.hasLoaded && !model.isSending && !model.isLoading && !model.deliveryUncertain
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !model.isLoading { refreshControl.endRefreshing() }
        let empty = UILabel()
        empty.text = model.hasLoaded ? "暂无私信，可以发送第一条消息" : ""
        empty.font = .preferredFont(forTextStyle: .subheadline)
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        empty.numberOfLines = 0
        tableView.backgroundView = model.messages.isEmpty ? empty : nil
        guard renderedMessages != model.messages else { return }
        let nearBottom = renderedMessages.isEmpty || tableView.contentSize.height - tableView.contentOffset.y - tableView.bounds.height < 120
        renderedMessages = model.messages
        tableView.reloadData()
        tableView.layoutIfNeeded()
        if nearBottom, !renderedMessages.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: renderedMessages.count - 1, section: 0), at: .bottom, animated: false)
        }
    }

    @objc private func refresh() { Task { [weak self] in await self?.model.load() } }
    @objc private func confirmRetry() { model.acknowledgeUncertainDelivery() }
    @objc private func send() {
        Task { [weak self] in
            guard let self else { return }
            await model.send()
            if model.draft.isEmpty, !renderedMessages.isEmpty {
                tableView.scrollToRow(at: IndexPath(row: renderedMessages.count - 1, section: 0), at: .bottom, animated: true)
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        model.draft = textView.text
        render()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { renderedMessages.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as? MessageBubbleCell else {
            return UITableViewCell()
        }
        let message = renderedMessages[indexPath.row]
        let showsTimestamp = indexPath.row == 0 || message.createdAt.timeIntervalSince(renderedMessages[indexPath.row - 1].createdAt) > 300
        cell.configure(message, isMine: message.senderID == model.currentUserID, showsTimestamp: showsTimestamp, availableWidth: tableView.bounds.width) { [weak self] uid in
            self?.openProfile(uid: uid)
        }
        return cell
    }
}
