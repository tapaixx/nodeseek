import UIKit
import XCTest
import WebKit
@testable import nodeseek

@MainActor
final class ManualSiteVerificationTests: XCTestCase {
    func testCloudflareResponseOffersManualRecoveryAndStopsAutomaticRepeatedReads() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerificationChallengeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        VerificationChallengeURLProtocol.challenged = true
        VerificationChallengeURLProtocol.requests = 0
        let verification = SiteVerificationCoordinator()
        let client = NodeSeekNotificationClient(session: session, verification: verification, cookiePreparer: {})
        do {
            _ = try await client.loadUnreadCount()
            XCTFail("Expected verification challenge")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("手动验证"), "验证响应应提供可操作的恢复说明")
        }
        VerificationChallengeURLProtocol.requests = 0
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let accounts = CurrentAccountStore(userDefaults: defaults)
        await accounts.save(AccountResponse(displayName: "Me", isLoggedIn: true, avatarURL: nil, profileURL: URL(string: "https://www.nodeseek.com/space/10"), stats: []))
        let center = AppMessageCenter(client: client, verification: verification, accounts: accounts, defaults: defaults, isForeground: { true })
        await center.refresh()
        await center.refresh()
        await center.refresh()
        XCTAssertEqual(VerificationChallengeURLProtocol.requests, 0, "验证期间应暂停自动消息请求")
        VerificationChallengeURLProtocol.challenged = false
        verification.verified()
        for _ in 0..<200 {
            if VerificationChallengeURLProtocol.requests > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(VerificationChallengeURLProtocol.requests, 1, "完成验证后应恢复消息读取")
    }

    func testFreshSuccessfulReadAlsoRestoresAutomaticChecks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerificationChallengeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let verification = SiteVerificationCoordinator()
        verification.require(NodeSeekSite.baseURL)
        VerificationChallengeURLProtocol.challenged = false
        let client = NodeSeekNotificationClient(session: session, verification: verification, cookiePreparer: {})
        _ = try await client.loadUnreadCount()
        XCTAssertFalse(verification.automaticRequestsPaused)
        verification.begin()
        verification.recordSuccess()
        XCTAssertTrue(verification.automaticRequestsPaused)
    }

    func testVerificationCapturesClearanceBeforeResumingAndKeepsLogin() async throws {
        let storage = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let login = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "unit-test-login", .domain: ".nodeseek.com", .path: "/"]))
        let clearance = try XCTUnwrap(HTTPCookie(properties: [.name: "cf_clearance", .value: "unit-test-clearance", .domain: ".nodeseek.com", .path: "/"]))
        storage.setCookie(login)
        let webStore = VerificationCookieStore(cookies: [login, clearance])
        let session = NodeSeekCookieSession(bridge: CookieBridge(webCookieStore: webStore, urlCookieStorage: storage))
        let verification = SiteVerificationCoordinator()
        verification.require(NodeSeekSite.baseURL)
        let controller = SiteVerificationViewController(cookieSession: session, automaticallyLoadsPage: false, coordinator: verification)
        controller.loadViewIfNeeded()
        let blocked = await controller.finishIfVerified(url: NodeSeekSite.baseURL, html: "<html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/test.js'></script></html>")
        XCTAssertFalse(blocked)
        XCTAssertTrue(verification.automaticRequestsPaused)
        XCTAssertFalse(storage.cookies?.contains { $0.name == "cf_clearance" } ?? false)
        let allowed = await controller.finishIfVerified(url: NodeSeekSite.baseURL, html: "<html><main id=\"nsk-body\">NodeSeek</main></html>")
        XCTAssertTrue(allowed)
        XCTAssertFalse(verification.automaticRequestsPaused)
        XCTAssertEqual(storage.cookies?.first { $0.name == "cf_clearance" }?.value, "unit-test-clearance")
        XCTAssertEqual(storage.cookies?.first { $0.name == "session" }?.value, "unit-test-login")
    }

    func testIncompleteFailedOrExternalPageCannotFinishVerification() async {
        let session = VerificationCookieSessionSpy()
        let controller = SiteVerificationViewController(cookieSession: session, automaticallyLoadsPage: false, coordinator: SiteVerificationCoordinator())
        controller.loadViewIfNeeded()
        let empty = await controller.finishIfVerified(url: NodeSeekSite.baseURL, html: "")
        let failed = await controller.finishIfVerified(url: NodeSeekSite.baseURL, html: "Access denied", statusCode: 403)
        let foreign = await controller.finishIfVerified(url: URL(string: "https://example.com/")!, html: "<html>Done</html>")
        XCTAssertFalse(empty); XCTAssertFalse(failed); XCTAssertFalse(foreign)
        XCTAssertEqual(session.captureCount, 0)
        XCTAssertEqual(session.clearCount, 0)
    }

    func testFailedPageOffersVerificationAndLayoutWorksInBothThemes() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let verification = SiteVerificationCoordinator()
            verification.require(NodeSeekSite.baseURL)
            let errorView = UserContentErrorView(accessibilityIdentifier: "test-error", verification: verification)
            let button = try XCTUnwrap(errorView.arrangedSubviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "error-manual-verification" })
            XCTAssertFalse(button.isHidden)
            let controller = SiteVerificationViewController(cookieSession: VerificationCookieSessionSpy(), automaticallyLoadsPage: false, coordinator: verification)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = MessageNavigationController(rootViewController: controller)
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.webView.loadHTMLString("<html><meta name='viewport' content='width=device-width, initial-scale=1'><body style='font:17px -apple-system;text-align:center;padding:80px 20px;color:#888'><h2>站点验证测试页面</h2><p>验证页面会在此显示</p></body></html>", baseURL: NodeSeekSite.baseURL)
            var pageText = ""
            for _ in 0..<300 {
                pageText = (try? await controller.webView.evaluateJavaScript("document.body.innerText")) as? String ?? ""
                if pageText.contains("站点验证测试页面") { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(pageText.contains("站点验证测试页面"))
            window.layoutIfNeeded()
            XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.filter { $0.accessibilityIdentifier == MessageNavigationBar.shortcutID }.count, 1)
            XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "验证后重试")
            XCTAssertTrue(controller.webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
            XCTAssertEqual(controller.webView.customUserAgent, WebRequestFingerprint.userAgent)
            XCTAssertGreaterThan(controller.webView.bounds.height, 300)
            XCTAssertGreaterThan(controller.webView.bounds.width, 300)
            let hint = try XCTUnwrap(controller.view.subviews.flatMap(\.subviews).first { $0.accessibilityIdentifier == "site-verification-hint" })
            XCTAssertLessThanOrEqual(hint.convert(hint.bounds, to: window).maxY, controller.webView.frame.minY)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = style == .light ? "verification-light" : "verification-dark"; attachment.lifetime = .keepAlways; add(attachment)
            let webImage = try await controller.webView.takeSnapshot(configuration: nil)
            let webAttachment = XCTAttachment(image: webImage)
            webAttachment.name = style == .light ? "verification-web-light" : "verification-web-dark"
            webAttachment.lifetime = .keepAlways
            add(webAttachment)
        }
    }

    func testSettingsOffersManualVerificationWithoutLoggingOut() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let accounts = CurrentAccountStore(userDefaults: defaults)
        let controller = SettingsViewController(currentAccountStore: accounts,
            pushAuthorizationStatusProvider: { .notDetermined }, autoCheckInSummaryProvider: { "未开启" })
        controller.loadViewIfNeeded()
        var entry: UITableViewCell?
        for section in 0..<controller.tableView.numberOfSections {
            for row in 0..<controller.tableView.numberOfRows(inSection: section) {
                let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: row, section: section))
                if cell.accessibilityIdentifier == "settings-site-verification-cell" { entry = cell }
            }
        }
        XCTAssertNotNil(entry, "Cloudflare 验证后需要可点击的手动验证入口")
        XCTAssertEqual(entry?.textLabel?.text, "手动站点验证")
    }
}

private final class VerificationChallengeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var challenged = true
    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.challenged ? 403 : 200, httpVersion: nil,
            headerFields: Self.challenged ? ["Content-Type": "text/html", "cf-mitigated": "challenge"] : ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.challenged ? "<html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/test.js'></script></html>" : #"{"success":true,"unreadCount":{"message":0,"atMe":0,"reply":0,"all":0}}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override nonisolated func stopLoading() {}
}

@MainActor
private final class VerificationCookieStore: WebCookieStore {
    var cookies: [HTTPCookie]
    init(cookies: [HTTPCookie]) { self.cookies = cookies }
    func allCookies() async -> [HTTPCookie] { cookies }
    func setCookie(_ cookie: HTTPCookie) async { cookies.removeAll { $0.name == cookie.name }; cookies.append(cookie) }
    func deleteCookie(_ cookie: HTTPCookie) async { cookies.removeAll { $0.name == cookie.name } }
}

@MainActor
private final class VerificationCookieSessionSpy: NodeSeekCookieSessionManaging {
    var captureCount = 0
    var clearCount = 0
    func prepareWebViewLoad(userInterfaceStyle: UIUserInterfaceStyle?) async {}
    func captureWebViewSession() async { captureCount += 1 }
    func prepareHTTPLoad() async {}
    func prepareMediaRequest() async {}
    func clearLoginSession() async { clearCount += 1 }
}
