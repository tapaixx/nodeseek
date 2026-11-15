//
//  UserContentListChrome.swift
//  nodeseek
//
//  Created by Codex on 2026/5/11.
//

import UIKit

enum UserContentDisplayMode {
    case content
    case skeleton
    case firstPageError
}

final class UserContentErrorView: UIStackView {
    let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let verificationButton = UIButton(type: .system)
    private let verification: SiteVerificationCoordinator
    var onRetry: (() -> Void)?

    init(accessibilityIdentifier: String, verification: SiteVerificationCoordinator? = nil) {
        self.verification = verification ?? .shared
        super.init(frame: .zero)
        axis = .vertical
        alignment = .center
        spacing = 10
        isHidden = true
        self.accessibilityIdentifier = accessibilityIdentifier
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = "加载失败"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = ReadingColors.text
        titleLabel.adjustsFontForContentSizeCategory = true

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = true

        var configuration = UIButton.Configuration.filled()
        configuration.title = "重试"
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        retryButton.configuration = configuration
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        addArrangedSubview(titleLabel)
        addArrangedSubview(messageLabel)
        addArrangedSubview(retryButton)
        verificationButton.setTitle("手动验证", for: .normal)
        verificationButton.accessibilityIdentifier = "error-manual-verification"
        verificationButton.addTarget(self, action: #selector(verifyTapped), for: .touchUpInside)
        let touchHeight = verificationButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        touchHeight.priority = .defaultHigh
        touchHeight.isActive = true
        addArrangedSubview(verificationButton)
        NotificationCenter.default.addObserver(self, selector: #selector(updateVerification), name: SiteVerificationCoordinator.didChange, object: self.verification)
        updateVerification()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func updateVerification() { verificationButton.isHidden = verification.requiredURL == nil }
    @objc private func verifyTapped() {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                verification.present(from: controller) { [weak self] in self?.onRetry?() }
                return
            }
            responder = current.next
        }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

final class UserContentFooterView: UIView {
    private let indicator = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 56))
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        indicator.startAnimating()
    }

    func stopAnimating() {
        indicator.stopAnimating()
    }
}
