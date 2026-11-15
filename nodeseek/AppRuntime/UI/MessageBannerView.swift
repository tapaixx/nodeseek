import UIKit

final class MessageBannerView: UIView {
    private var dismissal: DispatchWorkItem?
    private let action: () -> Void

    init(events: [InAppMessageEvent], action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.separator.cgColor
        layer.borderWidth = 0.5
        layer.shadowColor = UIColor.label.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        let tap = UIButton(type: .system)
        let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        let title = UILabel(); title.font = .preferredFont(forTextStyle: .subheadline); title.textColor = .label; title.numberOfLines = 2
        title.text = events.last?.title ?? "新消息"
        let body = UILabel(); body.font = .preferredFont(forTextStyle: .caption1); body.textColor = .secondaryLabel; body.numberOfLines = 1
        body.text = events.count > 1 ? "另有 \(events.count - 1) 条新消息，点击查看" : events.last?.body
        let text = UIStackView(arrangedSubviews: [title, body]); text.axis = .vertical; text.spacing = 3
        let row = UIStackView(arrangedSubviews: [icon, text]); row.spacing = 12; row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        tap.addSubview(row)
        tap.accessibilityLabel = [title.text, body.text].compactMap { $0 }.joined(separator: "，")
        tap.accessibilityIdentifier = "message-banner-open"
        tap.addAction(UIAction { [weak self] _ in self?.action(); self?.dismiss() }, for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = "关闭消息提醒"
        close.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)
        for view in [tap, close] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            tap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), tap.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tap.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), tap.trailingAnchor.constraint(equalTo: close.leadingAnchor),
            row.leadingAnchor.constraint(equalTo: tap.leadingAnchor), row.trailingAnchor.constraint(equalTo: tap.trailingAnchor),
            row.topAnchor.constraint(equalTo: tap.topAnchor), row.bottomAnchor.constraint(equalTo: tap.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(greaterThanOrEqualToConstant: 68)
        ])
        accessibilityIdentifier = "in-app-message-banner"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(in window: UIWindow) {
        translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
            leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
        alpha = 0; transform = CGAffineTransform(translationX: 0, y: -12)
        UIView.animate(withDuration: 0.2) { self.alpha = 1; self.transform = .identity }
        UIAccessibility.post(notification: .announcement, argument: "收到新消息")
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
    func dismiss() {
        dismissal?.cancel(); dismissal = nil
        UIView.animate(withDuration: 0.18, animations: { self.alpha = 0 }) { _ in self.removeFromSuperview() }
    }
}
