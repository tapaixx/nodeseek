import UIKit
import WebKit

/// 每個面板獨立登入；僅保存該面板的會話，不保存密碼或 GitHub Cookie。
final class ProbePanelLoginViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let baseURL: URL
    private let instanceID: UUID
    private let sessions: ProbeSessionStoring
    private let onSaved: () -> Void
    private let browser: WKWebView
    private let statusLabel = UILabel()
    private var isVerifying = false

    init(baseURL: URL, instanceID: UUID, sessions: ProbeSessionStoring, onSaved: @escaping () -> Void) {
        self.baseURL = baseURL
        self.instanceID = instanceID
        self.sessions = sessions
        self.onSaved = onSaved
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        browser = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        title = "登录极简探针"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        browser.navigationDelegate = self
        browser.uiDelegate = self
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成登录", primaryAction: UIAction { [weak self] _ in self?.verifyAndSave() })
        statusLabel.text = "在面板完成登录后，点击“完成登录”。登录状态仅保存在本机。"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        [statusLabel, browser].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            browser.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor), browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        Task { [weak self] in
            guard let self else { return }
            if let saved = sessions.session(instanceID: instanceID, baseURL: baseURL), let host = baseURL.host,
               let cookie = HTTPCookie(properties: [.name: "monitor_session", .value: saved.value,
                                                    .domain: host, .path: "/", .secure: "TRUE",
                                                    .expires: saved.expiresAt ?? Date().addingTimeInterval(86_400)]) {
                await browser.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            browser.load(URLRequest(url: baseURL.appendingPathComponent("admin/nodes")))
        }
    }

    private func verifyAndSave() {
        guard !isVerifying else { return }
        isVerifying = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { isVerifying = false; navigationItem.rightBarButtonItem?.isEnabled = true }
            do {
                let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard let saved = cookies.compactMap({ ProbePanelSession(cookie: $0, baseURL: baseURL) }).first else {
                    throw ProbeFetchError.unauthorized
                }
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCache = nil
                let client = URLSession(configuration: config, delegate: SameHostRedirectDelegate(), delegateQueue: nil)
                defer { client.invalidateAndCancel() }
                var request = URLRequest(url: baseURL.appendingPathComponent("api/me"), timeoutInterval: 15)
                request.setValue(saved.header(), forHTTPHeaderField: "Cookie")
                let (data, response) = try await client.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["authed"] as? Bool == true else { throw ProbeFetchError.unauthorized }
                try sessions.save(saved, instanceID: instanceID, baseURL: baseURL)
                onSaved()
                dismiss(animated: true)
            } catch {
                statusLabel.text = (error as? ProbeCredentialError)?.localizedDescription ?? "登录尚未完成或已经过期，请在页面登录后重试。"
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme?.lowercased() == "https" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}
