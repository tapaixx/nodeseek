import UIKit

@MainActor
protocol MessageParticipantLoading {
    func loadProfile(uid: Int) async throws -> UserProfileRecord
    func loadDiscussions(uid: Int, page: Int) async throws -> [UserDiscussionRecord]
}

extension NodeSeekUserContentClient: MessageParticipantLoading {}

final class MessageParticipantHeaderView: UIView {
    let profileButton = UIControl()
    let postButton = UIButton(type: .system)
    private let disclosureButton = UIButton(type: .system)
    private let detailsStack = UIStackView()
    private(set) var isExpanded = false
    var onExpansionChanged: (() -> Void)?
    private let avatar = MessageAvatarImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private var loadedUID: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        avatar.layer.cornerRadius = 12
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2
        [nameLabel, detailLabel].forEach { $0.adjustsFontForContentSizeCategory = true }
        let text = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 4
        text.isUserInteractionEnabled = false
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [avatar, text, chevron])
        row.isUserInteractionEnabled = false
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        profileButton.addSubview(row)
        profileButton.accessibilityIdentifier = "message-participant-profile"
        profileButton.accessibilityTraits = .button
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 42), avatar.heightAnchor.constraint(equalToConstant: 42),
            row.leadingAnchor.constraint(equalTo: profileButton.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: profileButton.trailingAnchor),
            row.topAnchor.constraint(equalTo: profileButton.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: profileButton.bottomAnchor, constant: -10)
        ])
        postButton.contentHorizontalAlignment = .leading
        postButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        postButton.titleLabel?.lineBreakMode = .byTruncatingTail
        postButton.setImage(UIImage(systemName: "doc.text"), for: .normal)
        postButton.accessibilityIdentifier = "message-participant-latest-post"
        postButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        detailsStack.axis = .vertical
        detailsStack.addArrangedSubview(profileButton)
        detailsStack.addArrangedSubview(postButton)
        detailsStack.isHidden = true
        disclosureButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        disclosureButton.contentHorizontalAlignment = .leading
        disclosureButton.setTitleColor(.secondaryLabel, for: .normal)
        disclosureButton.tintColor = .secondaryLabel
        disclosureButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        disclosureButton.accessibilityIdentifier = "message-participant-toggle"
        disclosureButton.addAction(UIAction { [weak self] _ in self?.toggleDetails() }, for: .touchUpInside)
        updateDisclosure()
        let stack = UIStackView(arrangedSubviews: [disclosureButton, detailsStack])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func toggleDetails() {
        isExpanded.toggle()
        detailsStack.isHidden = !isExpanded
        backgroundColor = isExpanded ? .secondarySystemGroupedBackground : .clear
        updateDisclosure()
        onExpansionChanged?()
    }

    private func updateDisclosure() {
        disclosureButton.setTitle(isExpanded ? "  收起对方资料" : "  对方资料", for: .normal)
        disclosureButton.setImage(UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down",
                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)), for: .normal)
        disclosureButton.accessibilityValue = isExpanded ? "已展开" : "已收起"
        disclosureButton.accessibilityHint = isExpanded ? "收起等级、注册时间和最近主题" : "展开等级、注册时间和最近主题"
    }

    func configure(uid: Int, name: String, profile: UserProfileRecord?, post: UserDiscussionRecord?) {
        nameLabel.text = name
        if let profile {
            var details = ["Lv.\(profile.rank)"]
            if let date = profile.createdAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/M/d"
                details.append("注册于 \(formatter.string(from: date))")
            }
            detailLabel.text = details.joined(separator: " · ")
        } else {
            detailLabel.text = "点击查看账户资料"
        }
        profileButton.accessibilityLabel = "\(name)，\(detailLabel.text ?? "")，查看主页"
        postButton.isHidden = post == nil
        postButton.setTitle(post.map { "  最近主题 · \($0.title)" }, for: .normal)
        if loadedUID != uid {
            loadedUID = uid
            avatar.load(uid: uid)
        }
    }
}

final class MessageAvatarImageView: UIImageView {
    private let placeholder = UIImageView(image: UIImage(systemName: "person.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGray3
        placeholder.tintColor = .tertiaryLabel
        placeholder.contentMode = .scaleAspectFit
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.55),
            placeholder.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(uid: Int) {
        placeholder.isHidden = false
        AvatarImageRequest(url: NodeSeekNotificationURLBuilder.avatarURL(memberID: uid), requestID: "chat-avatar-\(uid)").into(self) { [weak self] result in
            if case .success = result { self?.placeholder.isHidden = true }
        }
    }
}
