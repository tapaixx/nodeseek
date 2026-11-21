import UIKit
import WebKit

final class TradeAuthorizationViewController: BaseWebViewController {
    static let entryURL = URL(string: "https://agent.nodeseek.org/login?next=%2Fchat%2F")!
    private weak var authorizationWebView: WKWebView?
    private weak var authorizationController: UINavigationController?
    private let retryButton = UIButton(type: .system)
    private var urlObservation: NSKeyValueObservation?
    private var onAuthorized: (() -> Void)?
    private let verifySession: () async throws -> Bool
    private var isVerifyingSession = false
    private var didRequestConnect = false

    override var usesCustomUserAgent: Bool { false }

    init(automaticallyLoadsPage: Bool = true, verifySession: @escaping () async throws -> Bool, onAuthorized: @escaping () -> Void) {
        self.verifySession = verifySession
        self.onAuthorized = onAuthorized
        super.init(initialURL: Self.entryURL, pageTitle: TradeText.text("NodeSeek 授权"), automaticallyLoadsPage: automaticallyLoadsPage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let url = change.newValue ?? nil else { return }
            Task { @MainActor [weak self] in self?.checkAuthorized(url) }
        }
    }

    override func configureNavigationItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.onAuthorized = nil
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: TradeText.text("检查登录状态"), primaryAction: UIAction { [weak self] _ in
            self?.verifyAuthorization()
        })
    }

    private func checkAuthorized(_ url: URL) {
        guard presentedViewController == nil, Self.isTradeURL(url),
              url.path == "/chat" || url.path == "/chat/" else { return }
        verifyAuthorization()
    }

    private func verifyAuthorization() {
        guard !isVerifyingSession, onAuthorized != nil, presentedViewController == nil else { return }
        isVerifyingSession = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer {
                isVerifyingSession = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            let isAuthorized = (try? await verifySession()) == true
            guard let onAuthorized, view.window != nil else { return }
            guard isAuthorized else {
                showSessionHint()
                return
            }
            self.onAuthorized = nil
            dismissAfterPresentation(navigationController ?? self, completion: onAuthorized)
        }
    }

    private func showSessionHint() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: TradeText.text("尚未确认交易登录"),
            message: TradeText.text("检查登录状态不会发起 connect。若官方提示授权次数已达上限，请等待限制解除；论坛登录态不能替代交易授权。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: TradeText.text("关闭"), style: .cancel))
        present(alert, animated: true)
    }

    override func configureWebView() {
        configureWebViewProperties()
        installWebViewLayout(topAnchor: view.safeAreaLayoutGuide.topAnchor)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = NSLocalizedString("网页加载失败，点按重试", tableName: "Trade", comment: "")
        configuration.titleLineBreakMode = .byWordWrapping
        retryButton.configuration = configuration
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addAction(UIAction { [weak self] _ in self?.reloadCurrentPage() }, for: .touchUpInside)
        view.addSubview(retryButton)
        NSLayoutConstraint.activate([
            retryButton.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            retryButton.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        retryButton.isHidden = true
        loadingIndicator.startAnimating()
    }

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        retryButton.isHidden = true
        loadingIndicator.stopAnimating()
        if let url = webView.url { checkAuthorized(url) }
    }

    override func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(in: webView, error: error)
    }

    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(in: webView, error: error)
    }

    private func handleFailure(in webView: WKWebView, error: Error) {
        guard (error as? URLError)?.code != .cancelled else { return }
        if webView === self.webView {
            loadingIndicator.stopAnimating()
            retryButton.isHidden = false
        } else if webView === authorizationWebView {
            let alert = UIAlertController(
                title: NSLocalizedString("NodeSeek 授权", tableName: "Trade", comment: ""),
                message: NSLocalizedString("授权页面未能打开，请重试。", tableName: "Trade", comment: ""),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("关闭", tableName: "Trade", comment: ""), style: .cancel))
            closeAuthorization { [weak self] in self?.present(alert, animated: true) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if webView === authorizationWebView {
            return decisionHandler(Self.isNodeSeekURL(url) ? .allow : .cancel)
        }
        if Self.isTradeURL(url) || action.targetFrame == nil {
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true {
            openExternalLink(url)
        }
        decisionHandler(.cancel)
    }

    override func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                          for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, action.targetFrame == nil, let url = action.request.url else { return nil }
        if action.sourceFrame.isMainFrame, Self.allowsAuthorizationPopup(from: action.sourceFrame.request.url, to: url) {
            guard view.window != nil, presentedViewController == nil else { return nil }
            // 一次登录流程只请求一次授权；回跳异常时先检查会话，避免反复消耗官方额度。
            guard !didRequestConnect else {
                verifyAuthorization()
                return nil
            }
            didRequestConnect = true
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = WebRequestFingerprint.userAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            let controller = UIViewController()
            controller.title = NSLocalizedString("NodeSeek 授权", tableName: "Trade", comment: "")
            controller.view = popup
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.closeAuthorization()
            })
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .fullScreen
            authorizationWebView = popup
            authorizationController = navigation
            present(navigation, animated: true)
            return popup
        }
        if Self.isTradeURL(url) {
            webView.load(action.request)
        } else if action.navigationType == .linkActivated {
            openExternalLink(url)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === authorizationWebView { closeAuthorization() }
    }

    private func closeAuthorization(completion: (() -> Void)? = nil) {
        let popup = authorizationWebView
        let controller = authorizationController
        authorizationController = nil
        authorizationWebView = nil
        popup?.stopLoading()
        guard let controller else { return }
        dismissAfterPresentation(controller) { [weak self] in
            if let completion { completion() }
            else if let self, let url = self.webView.url { self.checkAuthorized(url) }
        }
    }

    private func dismissAfterPresentation(_ controller: UIViewController, completion: @escaping () -> Void) {
        // 复用登录态时回调可能早于弹窗动画结束；先等展示完成，避免关闭请求丢失。
        if controller.isBeingPresented, let transition = controller.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in
                controller.dismiss(animated: true, completion: completion)
            }
        } else {
            controller.dismiss(animated: true, completion: completion)
        }
    }

    private func openExternalLink(_ url: URL) {
        guard url.scheme == "https" else { return }
        UIApplication.shared.open(url)
    }

    static func allowsAuthorizationPopup(from source: URL?, to destination: URL) -> Bool {
        guard let source, isTradeURL(source) else { return false }
        return isNodeSeekURL(destination) && destination.path == "/connect"
    }

    private static func isTradeURL(_ url: URL) -> Bool {
        isStandardHTTPS(url) && url.host == entryURL.host
    }

    private static func isNodeSeekURL(_ url: URL) -> Bool {
        isStandardHTTPS(url) && (url.host == "www.nodeseek.com" || url.host == "nodeseek.com")
    }

    private static func isStandardHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
}
