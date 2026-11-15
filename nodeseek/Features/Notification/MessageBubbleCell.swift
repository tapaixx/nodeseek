import UIKit

final class MessageBubbleCell: UITableViewCell {
    private let avatarButton = UIButton(type: .custom)
    private let avatar = MessageAvatarImageView(frame: .zero)
    private let bubble = UITextView()
    private let dateLabel = UILabel()
    private var incoming: [NSLayoutConstraint] = []
    private var outgoing: [NSLayoutConstraint] = []
    private var bubbleWidth: NSLayoutConstraint!
    private var bubbleTop: NSLayoutConstraint!
    private var senderID: Int?
    private var onProfile: ((Int) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        avatar.layer.cornerRadius = 11
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatar)
        avatarButton.accessibilityIdentifier = "message-sender-avatar"
        avatarButton.addAction(UIAction { [weak self] _ in
            guard let self, let senderID else { return }
            onProfile?(senderID)
        }, for: .touchUpInside)
        bubble.isEditable = false
        bubble.isScrollEnabled = false
        bubble.backgroundColor = .secondarySystemGroupedBackground
        bubble.dataDetectorTypes = [.link]
        bubble.layer.cornerRadius = 17
        bubble.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bubble.textContainer.lineFragmentPadding = 0
        bubble.adjustsFontForContentSizeCategory = true
        bubble.linkTextAttributes = [.foregroundColor: UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        dateLabel.font = .preferredFont(forTextStyle: .caption1)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel
        dateLabel.textAlignment = .center
        [bubble, avatarButton, dateLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview($0) }
        bubbleWidth = bubble.widthAnchor.constraint(equalToConstant: 100)
        bubbleTop = bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
        incoming = [avatarButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
                    bubble.leadingAnchor.constraint(equalTo: avatarButton.trailingAnchor, constant: 8)]
        outgoing = [avatarButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
                    bubble.trailingAnchor.constraint(equalTo: avatarButton.leadingAnchor, constant: -8)]
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalTo: avatarButton.widthAnchor), avatar.heightAnchor.constraint(equalTo: avatarButton.heightAnchor),
            avatar.leadingAnchor.constraint(equalTo: avatarButton.leadingAnchor), avatar.topAnchor.constraint(equalTo: avatarButton.topAnchor),
            avatarButton.widthAnchor.constraint(equalToConstant: 36), avatarButton.heightAnchor.constraint(equalToConstant: 36),
            avatarButton.topAnchor.constraint(equalTo: bubble.topAnchor),
            avatarButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6),
            dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bubbleTop, bubbleWidth, bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        AvatarImageLoader.shared.cancel(on: avatar)
        senderID = nil
        onProfile = nil
    }

    override func layoutSubviews() {
        updateBubbleWidth()
        super.layoutSubviews()
    }

    private func updateBubbleWidth(availableWidth: CGFloat? = nil) {
        let width = availableWidth ?? contentView.bounds.width
        guard width > 0, let text = bubble.attributedText else { return }
        let maximum = min(420, width * 0.72)
        let size = text.boundingRect(with: CGSize(width: maximum - 24, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        bubbleWidth.constant = min(maximum, max(44, ceil(size.width) + 25))
    }

    func configure(_ message: NodeSeekDirectMessage, isMine: Bool, showsTimestamp: Bool, availableWidth: CGFloat, onProfile: @escaping (Int) -> Void) {
        self.onProfile = onProfile
        NSLayoutConstraint.deactivate(incoming + outgoing)
        NSLayoutConstraint.activate(isMine ? outgoing : incoming)
        bubble.backgroundColor = isMine ? UIColor.systemBlue.withAlphaComponent(0.14) : .secondarySystemGroupedBackground
        let rendered: NSAttributedString
        if message.isMarkdown, let markdown = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            rendered = NSAttributedString(markdown)
        } else {
            rendered = NSAttributedString(string: message.content)
        }
        let text = NSMutableAttributedString(attributedString: rendered)
        text.addAttributes([.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label], range: NSRange(location: 0, length: text.length))
        bubble.attributedText = text
        dateLabel.isHidden = !showsTimestamp
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(message.createdAt) ? "HH:mm" : "M/d HH:mm"
        dateLabel.text = showsTimestamp ? formatter.string(from: message.createdAt) : nil
        bubbleTop.constant = showsTimestamp ? 40 : 6
        avatarButton.accessibilityLabel = isMine ? "我的头像，查看主页" : "对方头像，查看主页"
        if senderID != message.senderID {
            senderID = message.senderID
            avatar.load(uid: message.senderID)
        }
        updateBubbleWidth(availableWidth: availableWidth)
    }
}
