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
    private var refreshTask: Task<Void, Never>?
    private var renderedMessages: [NodeSeekDirectMessage] = []

    init(
        participantID: Int,
        participantName: String = "私信",
        client: NodeSeekMessageClientProtocol? = nil,
        currentAccountStore: CurrentAccountStore = .shared
    ) {
        model = MessageConversationViewModel(
            participantID: participantID, participantName: participantName,
            client: client ?? NodeSeekMessageClient(), currentAccountStore: currentAccountStore
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
        view.backgroundColor = .systemBackground
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
        input.backgroundColor = .secondarySystemBackground
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
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        let composer = UIStackView(arrangedSubviews: [input, sendButton])
        composer.alignment = .bottom
        composer.spacing = 10

        [status, tableView, composer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            input.heightAnchor.constraint(equalToConstant: 88),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        let browser = UIAction(title: "在网页中打开", image: UIImage(systemName: "globe")) { [weak self] _ in
            guard let self else { return }
            navigationController?.pushViewController(
                NodeSeekWebViewController(url: NodeSeekMessageClient.webURL(participantID: model.participantID)), animated: true
            )
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [browser]))
    }

    private func render() {
        title = model.participantName
        statusLabel.text = model.errorMessage ?? (model.isLoading && !model.hasLoaded ? "正在加载私信…" : nil)
        statusLabel.isHidden = statusLabel.text == nil
        retryButton.isHidden = model.errorMessage == nil
        retryButton.isEnabled = !model.isLoading && !model.isSending
        confirmRetryButton.isHidden = !model.deliveryUncertain
        input.isEditable = !model.isSending
        if input.text != model.draft { input.text = model.draft }
        placeholder.isHidden = !model.draft.isEmpty
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
    @objc private func send() { Task { [weak self] in await self?.model.send() } }

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
        cell.configure(message, isMine: message.senderID == model.currentUserID)
        return cell
    }
}

private final class MessageBubbleCell: UITableViewCell {
    private let bubble = UITextView()
    private let dateLabel = UILabel()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bubble.isEditable = false
        bubble.isScrollEnabled = false
        bubble.dataDetectorTypes = [.link]
        bubble.layer.cornerRadius = 14
        bubble.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        bubble.adjustsFontForContentSizeCategory = true
        dateLabel.font = .preferredFont(forTextStyle: .caption2)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        [bubble, dateLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        NSLayoutConstraint.activate([
            dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bubble.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ message: NodeSeekDirectMessage, isMine: Bool) {
        leading.isActive = !isMine
        trailing.isActive = isMine
        bubble.backgroundColor = isMine ? .tertiarySystemFill : .secondarySystemBackground
        let rendered: NSAttributedString
        if message.isMarkdown, let markdown = try? AttributedString(
            markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            rendered = NSAttributedString(markdown)
        } else {
            rendered = NSAttributedString(string: message.content)
        }
        let text = NSMutableAttributedString(attributedString: rendered)
        text.addAttributes([.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label], range: NSRange(location: 0, length: text.length))
        bubble.attributedText = text
        dateLabel.text = (isMine ? "我 · " : "") + NodeSeekNotificationDateParser.displayText(from: message.createdAt)
        dateLabel.textAlignment = isMine ? .right : .left
    }
}
