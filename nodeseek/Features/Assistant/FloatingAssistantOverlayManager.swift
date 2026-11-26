import Combine
import SwiftUI
import UIKit

/// 全局可拖曳贴边悬浮 AI 助手管理器。
/// 挂载在主窗口上，提供随时呼出、状态指示、长按快捷菜单与半屏悬浮对话面板呈现。
@MainActor
final class FloatingAssistantOverlayManager: NSObject {
    static let shared = FloatingAssistantOverlayManager()

    private weak var window: UIWindow?
    private let store: AssistantSessionStore
    private let settings: FloatingAssistantSettings

    private var floatingContainer: FloatingControlContainerView?
    private var orbButton: FloatingAssistantOrbButton?
    private weak var presentedSheetController: UIViewController?

    private var cancellables: Set<AnyCancellable> = []
    private var settingsObserver: NSObjectProtocol?
    private var keyboardShowObserver: NSObjectProtocol?
    private var keyboardHideObserver: NSObjectProtocol?
    private var idleDimWorkItem: DispatchWorkItem?
    private var isKeyboardVisible = false

    private let orbSize: CGFloat = 52

    init(
        store: AssistantSessionStore = .shared,
        settings: FloatingAssistantSettings = .shared
    ) {
        self.store = store
        self.settings = settings
        super.init()
        observeState()
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let keyboardShowObserver { NotificationCenter.default.removeObserver(keyboardShowObserver) }
        if let keyboardHideObserver { NotificationCenter.default.removeObserver(keyboardHideObserver) }
        idleDimWorkItem?.cancel()
    }

    func attach(window: UIWindow) {
        self.window = window
        ensureOrbInstalled(in: window)
        updateOrbVisibility(animated: false)
    }

    func bringToFrontIfNeeded() {
        guard let window, let floatingContainer else { return }
        if floatingContainer.superview !== window {
            ensureOrbInstalled(in: window)
        } else {
            window.bringSubviewToFront(floatingContainer)
        }
        updateFloatingBounds(in: window)
    }

    /// 展开半屏/全屏悬浮对话面板（可由悬浮球、详情页按钮或快捷菜单触发）。
    func presentPanel(from presenter: UIViewController? = nil, quickPrompt: String? = nil) {
        store.hasUnreadReply = false
        store.isPanelPresented = true
        updateOrbVisibility(animated: true)

        if let existing = presentedSheetController, existing.presentingViewController != nil {
            if let quickPrompt {
                triggerQuickPromptIfReady(quickPrompt)
            }
            return
        }

        guard let host = presenter ?? topMostPresenter() else {
            store.isPanelPresented = false
            updateOrbVisibility(animated: false)
            return
        }

        let rootView = AssistantPanelView(
            store: store,
            onDismiss: { [weak self] in
                self?.dismissPanel()
            }
        )
        let hosting = AssistantPanelHostingController(rootView: rootView) { [weak self] in
            self?.handlePanelDismissed()
        }
        hosting.modalPresentationStyle = .pageSheet
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            // 半屏态下不压暗后面的帖子内容，真正实现边看帖子边与悬浮助手对话。
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.preferredCornerRadius = 22
        }

        presentedSheetController = hosting
        host.present(hosting, animated: true) { [weak self] in
            if let quickPrompt {
                self?.triggerQuickPromptIfReady(quickPrompt)
            }
        }
    }

    func dismissPanel() {
        guard let controller = presentedSheetController else {
            handlePanelDismissed()
            return
        }
        controller.dismiss(animated: true) { [weak self] in
            self?.handlePanelDismissed()
        }
    }

    // MARK: - Private Setup & State

    private func handlePanelDismissed() {
        presentedSheetController = nil
        store.isPanelPresented = false
        updateOrbVisibility(animated: true)
        scheduleIdleDim()
    }

    private func triggerQuickPromptIfReady(_ prompt: String) {
        guard store.isReadyToSend, !store.needsExternalConsent else { return }
        store.sendMessage(prompt)
    }

    private func observeState() {
        store.$isGenerating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] generating in
                self?.orbButton?.setGenerating(generating)
                if generating {
                    self?.cancelIdleDimAndRestoreAlpha()
                } else {
                    self?.scheduleIdleDim()
                }
            }
            .store(in: &cancellables)

        store.$hasUnreadReply
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unread in
                self?.orbButton?.setUnreadBadgeVisible(unread)
                if unread {
                    self?.cancelIdleDimAndRestoreAlpha()
                }
            }
            .store(in: &cancellables)

        store.$currentPageContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] context in
                self?.orbButton?.setContextAttached(context != nil)
            }
            .store(in: &cancellables)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: FloatingAssistantSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateOrbVisibility(animated: true)
            }
        }

        keyboardShowObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isKeyboardVisible = true
                self?.updateOrbVisibility(animated: true)
            }
        }

        keyboardHideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isKeyboardVisible = false
                self?.updateOrbVisibility(animated: true)
            }
        }
    }

    private func ensureOrbInstalled(in window: UIWindow) {
        floatingContainer?.removeFromSuperview()

        let container = FloatingControlContainerView(
            accessibilityIdentifier: "floating-ai-assistant-container",
            positionStorageKey: FloatingControlPositionKeys.aiAssistantOrb
        )
        let button = FloatingAssistantOrbButton(size: orbSize)
        button.accessibilityIdentifier = "floating-ai-assistant-orb"
        button.accessibilityLabel = ChatAssistantText.text("title")
        button.accessibilityHint = ChatAssistantText.text("orbAccessibilityHint")
        button.addTarget(self, action: #selector(orbTapped), for: .touchUpInside)
        button.addInteraction(UIContextMenuInteraction(delegate: self))

        container.hostControl(button)
        container.onAdsorbedEdgeChanged = { [weak self] _ in
            self?.scheduleIdleDim()
        }

        window.addSubview(container)
        self.floatingContainer = container
        self.orbButton = button

        let safe = window.safeAreaLayoutGuide.layoutFrame
        let defaultX = max(safe.maxX - orbSize - 14, 14)
        let defaultY = max(safe.maxY - orbSize - 132, safe.minY + 80)
        let anchorView = UIView(frame: CGRect(x: defaultX, y: defaultY, width: orbSize, height: orbSize))
        updateFloatingBounds(in: window)
        container.syncFrame(with: anchorView)

        button.setGenerating(store.isGenerating)
        button.setUnreadBadgeVisible(store.hasUnreadReply)
        button.setContextAttached(store.currentPageContext != nil)
        scheduleIdleDim()
    }

    private func updateFloatingBounds(in window: UIWindow) {
        guard let container = floatingContainer else { return }
        let safe = window.safeAreaLayoutGuide.layoutFrame
        let topInset = max(safe.minY + 12, 56)
        let bottomInset = max(window.bounds.maxY - safe.maxY + 16, 28)
        container.floatingEdgeInsets = UIEdgeInsets(top: topInset, left: 10, bottom: bottomInset, right: 10)
    }

    private func updateOrbVisibility(animated: Bool) {
        guard let container = floatingContainer else { return }
        let shouldShow = settings.isFloatingOrbEnabled && !store.isPanelPresented && !isKeyboardVisible

        if shouldShow {
            window?.bringSubviewToFront(container)
            container.isHidden = false
            let targetAlpha: CGFloat = (store.isGenerating || store.hasUnreadReply) ? 1.0 : 0.96
            if animated {
                UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.5) {
                    container.alpha = targetAlpha
                    container.transform = .identity
                }
            } else {
                container.alpha = targetAlpha
                container.transform = .identity
            }
            scheduleIdleDim()
        } else {
            idleDimWorkItem?.cancel()
            if animated {
                UIView.animate(withDuration: 0.18, animations: {
                    container.alpha = 0
                    container.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                }) { _ in
                    if !(self.settings.isFloatingOrbEnabled && !self.store.isPanelPresented && !self.isKeyboardVisible) {
                        container.isHidden = true
                    }
                }
            } else {
                container.alpha = 0
                container.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                container.isHidden = true
            }
        }
    }

    private func cancelIdleDimAndRestoreAlpha() {
        idleDimWorkItem?.cancel()
        guard let container = floatingContainer, !container.isHidden else { return }
        UIView.animate(withDuration: 0.2) {
            container.alpha = 1.0
        }
    }

    private func scheduleIdleDim() {
        idleDimWorkItem?.cancel()
        guard !store.isGenerating, !store.hasUnreadReply else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let container = self.floatingContainer,
                  !container.isHidden, !self.store.isGenerating, !self.store.hasUnreadReply else { return }
            UIView.animate(withDuration: 0.35) {
                container.alpha = 0.76
            }
        }
        idleDimWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: item)
    }

    @objc private func orbTapped() {
        cancelIdleDimAndRestoreAlpha()
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()
        presentPanel()
    }

    private func topMostPresenter() -> UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            if presented is UIAlertController { break }
            controller = presented
        }
        return controller
    }
}

extension FloatingAssistantOverlayManager: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []

            if self.store.currentPageContext?.kind == .post {
                actions.append(UIAction(
                    title: ChatAssistantText.text("postSummary"),
                    image: UIImage(systemName: "doc.text")
                ) { [weak self] _ in
                    self?.presentPanel(quickPrompt: ChatAssistantText.text("quickPromptSummarizePost"))
                })
                actions.append(UIAction(
                    title: ChatAssistantText.text("analysis"),
                    image: UIImage(systemName: "text.magnifyingglass")
                ) { [weak self] _ in
                    self?.presentPanel(quickPrompt: ChatAssistantText.text("quickPromptAnalyzePost"))
                })
            }

            actions.append(UIAction(
                title: ChatAssistantText.text("newConversation"),
                image: UIImage(systemName: "square.and.pencil")
            ) { [weak self] _ in
                self?.store.startNewSession()
                self?.presentPanel()
            })

            actions.append(UIAction(
                title: ChatAssistantText.text("hideFloatingOrb"),
                image: UIImage(systemName: "eye.slash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.settings.isFloatingOrbEnabled = false
            })

            return UIMenu(title: ChatAssistantText.text("title"), children: actions)
        }
    }
}

/// 监听面板被手势下拉关闭的 HostingController。
private final class AssistantPanelHostingController<Content: View>: UIHostingController<Content> {
    private let onDidDisappearDismissed: () -> Void

    init(rootView: Content, onDidDisappearDismissed: @escaping () -> Void) {
        self.onDidDisappearDismissed = onDidDisappearDismissed
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDidDisappearDismissed()
        }
    }
}

/// 精致毛玻璃悬浮球按钮（适配浅色/深色模式、上下文感知点、生成呼吸动画与未读圆点）。
private final class FloatingAssistantOrbButton: UIControl {
    private let orbSize: CGFloat
    private let shadowView = UIView()
    private let blurView: UIVisualEffectView
    private let surfaceTintView = UIView()
    private let iconView = UIImageView()
    private let contextDot = UIView()
    private let unreadDot = UIView()

    init(size: CGFloat) {
        self.orbSize = size
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.14) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.91, y: 0.91) : .identity
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateDynamicAppearance()
        }
    }

    func setGenerating(_ generating: Bool) {
        iconView.layer.removeAnimation(forKey: "pulse")
        if generating {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.88
            pulse.toValue = 1.16
            pulse.duration = 0.72
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            iconView.layer.add(pulse, forKey: "pulse")
        }
    }

    func setUnreadBadgeVisible(_ visible: Bool) {
        unreadDot.isHidden = !visible
    }

    func setContextAttached(_ attached: Bool) {
        contextDot.isHidden = !attached
    }

    private func setupViews() {
        backgroundColor = .clear

        shadowView.frame = bounds
        shadowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shadowView.isUserInteractionEnabled = false
        shadowView.layer.cornerRadius = orbSize / 2
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 6)
        shadowView.layer.shadowRadius = 14
        addSubview(shadowView)

        blurView.frame = bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = orbSize / 2
        blurView.clipsToBounds = true
        blurView.layer.borderWidth = 0.75
        addSubview(blurView)

        surfaceTintView.frame = bounds
        surfaceTintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surfaceTintView.isUserInteractionEnabled = false
        blurView.contentView.addSubview(surfaceTintView)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        iconView.image = UIImage(systemName: "sparkles", withConfiguration: symbolConfig)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(iconView)

        // 右下角微小上下文感应点（说明当前在帖子页，助手已感知当前内容）
        contextDot.translatesAutoresizingMaskIntoConstraints = false
        contextDot.layer.cornerRadius = 4
        contextDot.layer.borderWidth = 1.5
        contextDot.isHidden = true
        addSubview(contextDot)

        // 右上角未读回复提示点
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.backgroundColor = .systemBlue
        unreadDot.layer.cornerRadius = 5
        unreadDot.layer.borderWidth = 1.5
        unreadDot.isHidden = true
        addSubview(unreadDot)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),

            contextDot.widthAnchor.constraint(equalToConstant: 8),
            contextDot.heightAnchor.constraint(equalToConstant: 8),
            contextDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            contextDot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            unreadDot.widthAnchor.constraint(equalToConstant: 10),
            unreadDot.heightAnchor.constraint(equalToConstant: 10),
            unreadDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            unreadDot.topAnchor.constraint(equalTo: topAnchor, constant: 1)
        ])

        updateDynamicAppearance()
    }

    private func updateDynamicAppearance() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        shadowView.backgroundColor = isDark
            ? UIColor.secondarySystemBackground.withAlphaComponent(0.25)
            : UIColor.systemBackground.withAlphaComponent(0.9)
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = isDark ? 0.45 : 0.16

        blurView.layer.borderColor = (isDark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.08)).cgColor
        // 浅色下保持高对比极简墨黑底 + 白星芒，深色下通透亮银感，辨识度高且不花哨。
        surfaceTintView.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.label.withAlphaComponent(0.92)
        iconView.tintColor = isDark ? UIColor.label : UIColor.systemBackground

        contextDot.backgroundColor = .systemTeal
        contextDot.layer.borderColor = UIColor.systemBackground.cgColor
        unreadDot.layer.borderColor = UIColor.systemBackground.cgColor
    }
}
