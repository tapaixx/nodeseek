import UIKit
import WebKit

final class SiteVerificationViewController: BaseWebViewController {
    private let coordinator: SiteVerificationCoordinator
    private let onVerified: () -> Void
    private let hint = UILabel()
    private var finishing = false
    private var pageStatus: Int?

    init(initialURL: URL = NodeSeekSite.baseURL, cookieSession: NodeSeekCookieSessionManaging? = nil,
         automaticallyLoadsPage: Bool = true, coordinator: SiteVerificationCoordinator? = nil,
         onVerified: @escaping () -> Void = {}) {
        self.coordinator = coordinator ?? .shared
        self.onVerified = onVerified
        super.init(initialURL: NodeSeekVerificationRequired.safeURL(initialURL), pageTitle: "手动站点验证",
                   automaticallyLoadsPage: automaticallyLoadsPage, cookieSession: cookieSession)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func configureNavigationItems() {
        let done = UIBarButtonItem(title: "验证后重试", style: .done, target: self, action: #selector(finishTapped))
        done.accessibilityIdentifier = "site-verification-done"
        navigationItem.rightBarButtonItem = done
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
    }
    override func configureWebView() {
        configureWebViewProperties()
        hint.text = "请在下方完成 Cloudflare 验证，再点击「验证后重试」。登录状态会保留，验证期间暂停自动消息检查。"
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.accessibilityIdentifier = "site-verification-hint"
        hint.translatesAutoresizingMaskIntoConstraints = false
        let card = UIView(); card.backgroundColor = .secondarySystemBackground; card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        let reload = UIButton(type: .system)
        reload.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reload.accessibilityLabel = "刷新验证页"
        reload.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)
        reload.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card); card.addSubview(hint); card.addSubview(reload)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), hint.trailingAnchor.constraint(equalTo: reload.leadingAnchor, constant: -4),
            reload.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            reload.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            reload.widthAnchor.constraint(equalToConstant: 44), reload.heightAnchor.constraint(equalToConstant: 44),
            hint.topAnchor.constraint(equalTo: card.topAnchor, constant: 12), hint.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        installWebViewLayout(topAnchor: card.bottomAnchor)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); coordinator.begin() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); coordinator.end() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { pageStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode }
        decisionHandler(.allow)
    }
    @objc private func reloadTapped() { reloadCurrentPage() }
    @objc private func finishTapped() {
        guard !finishing else { return }
        Task { [weak self] in
            guard let self, !webView.isLoading, let url = webView.url,
                  let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else { return }
            if await finishIfVerified(url: url, html: html, statusCode: pageStatus ?? 0) { close(completed: true) }
        }
    }
    /// 先驗證目前文件、再回寫會話，避免仍在挑戰頁就關閉或重送寫入。
    func finishIfVerified(url: URL, html: String, statusCode: Int = 200) async -> Bool {
        guard !finishing, (200..<300).contains(statusCode), NodeSeekVerificationRequired.safeURL(url) == url, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let page = HTMLResponse(statusCode: statusCode, headers: [:], finalURL: url, html: html)
        guard ChallengeDetector().detect(response: page) == nil else {
            hint.text = "当前页面仍需要验证，请先完成下方验证，再点击「验证后重试」。"
            return false
        }
        finishing = true
        await webViewContext.captureWebViewSession()
        coordinator.verified()
        return true
    }
    private func close(completed: Bool = false) {
        let completion = completed ? onVerified : {}
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: true, completion: completion)
        } else {
            navigationController?.popViewController(animated: true)
            completion()
        }
    }
}
