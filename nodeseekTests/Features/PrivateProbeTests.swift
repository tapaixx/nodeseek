import XCTest
import UIKit
import WebKit
@testable import nodeseek

@MainActor
final class PrivateProbeTests: XCTestCase {
    private let baseURL = URL(string: "https://private.example.com")!

    private func cookie(value: String = "test-session", domain: String = "private.example.com", secure: Bool = true, expires: Date = Date().addingTimeInterval(600)) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "monitor_session", .value: value, .domain: domain, .path: "/", .expires: expires]
        if secure { properties[.secure] = "TRUE" }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    func testSessionRejectsOtherHostsExpiredAndInsecureCookies() throws {
        XCTAssertNotNil(ProbePanelSession(cookie: try cookie(), baseURL: baseURL))
        XCTAssertNil(ProbePanelSession(cookie: try cookie(domain: "other.example.com"), baseURL: baseURL))
        XCTAssertNil(ProbePanelSession(cookie: try cookie(secure: false), baseURL: baseURL))
        XCTAssertNil(ProbePanelSession(cookie: try cookie(expires: Date().addingTimeInterval(-10)), baseURL: baseURL))
    }

    func testPrivateSnapshotAndHistoryUseOnlyTheirPanelSession() async throws {
        let sessions = TestProbeSessions()
        let instance = ProbeInstance(name: "私有面板", baseURL: baseURL, adapterID: "monitor")
        try sessions.save(try XCTUnwrap(ProbePanelSession(cookie: cookie(), baseURL: baseURL)), instanceID: instance.id, baseURL: baseURL)
        let service = try makeService(sessions: sessions)
        let snapshot = try await service.snapshot(for: instance, reloadNodes: true)
        XCTAssertEqual(snapshot.nodes.first?.name, "Private server")
        let history = try await service.history(for: instance, nodeID: "1", hours: 1)
        XCTAssertEqual(history.count, 1)
        XCTAssertFalse(PrivateProbeURLProtocol.requests.isEmpty)
        XCTAssertTrue(PrivateProbeURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "monitor_session=test-session" })
        XCTAssertTrue(PrivateProbeURLProtocol.requests.allSatisfy { $0.httpShouldHandleCookies == false })
    }

    func testSessionIsNotReusedForAnotherInstanceOrHost() async throws {
        let sessions = TestProbeSessions()
        let id = UUID()
        try sessions.save(try XCTUnwrap(ProbePanelSession(cookie: cookie(), baseURL: baseURL)), instanceID: id, baseURL: baseURL)
        let service = try makeService(sessions: sessions)
        for (instanceID, url) in [(UUID(), baseURL), (id, URL(string: "https://another.example.com")!)] {
            do {
                _ = try await service.testConnection(baseURL: url, adapterID: "monitor", instanceID: instanceID)
                XCTFail("Expected authentication failure")
            } catch { XCTAssertEqual(error as? ProbeFetchError, .unauthorized) }
        }
        XCTAssertTrue(PrivateProbeURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    func testLogoutPreventsCachedPrivateSnapshotsFromBeingRead() async throws {
        let sessions = TestProbeSessions()
        var instance = ProbeInstance(name: "私有面板", baseURL: baseURL, adapterID: "monitor")
        instance.requiresAuthentication = true
        try sessions.save(try XCTUnwrap(ProbePanelSession(cookie: cookie(), baseURL: baseURL)), instanceID: instance.id, baseURL: baseURL)
        let service = try makeService(sessions: sessions)
        _ = try await service.snapshot(for: instance, reloadNodes: true)
        try sessions.remove(instanceID: instance.id, baseURL: baseURL)
        do {
            _ = try await service.snapshot(for: instance, reloadNodes: false)
            XCTFail("Expected authentication failure")
        } catch { XCTAssertEqual(error as? ProbeFetchError, .unauthorized) }
    }

    func testPrivateWidgetUsesAppCacheWithoutSendingAnonymousRequests() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = ProbeInstanceStore(defaults: defaults)
        var instance = ProbeInstance(name: "私有面板", baseURL: baseURL, adapterID: "monitor")
        instance.requiresAuthentication = true
        store.upsert(instance)
        store.saveSnapshot(ProbeSnapshot(nodes: [], statuses: [:], fetchedAt: Date().addingTimeInterval(-600)), for: instance.id)
        let service = PrivateProbePreviewService()
        _ = await ProbeWidgetLoader.load(store: store, service: service)
        let count = await service.snapshotCalls
        XCTAssertEqual(count, 0)
    }

    func testLoginBrowserHasIndependentEphemeralStorage() throws {
        let controller = ProbePanelLoginViewController(baseURL: baseURL, instanceID: UUID(), sessions: TestProbeSessions(), onSaved: {})
        controller.loadViewIfNeeded()
        let browser = try XCTUnwrap(controller.view.subviews.first { $0 is WKWebView } as? WKWebView)
        XCTAssertFalse(browser.configuration.websiteDataStore.isPersistent)
    }

    func testPrivateEditorOffersAccountMaintenanceAndSnapshots() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = ProbeInstanceStore(defaults: defaults)
        let sessions = TestProbeSessions()
        var instance = ProbeInstance(name: "私有面板", baseURL: baseURL, adapterID: "monitor")
        instance.requiresAuthentication = true
        store.upsert(instance)
        try sessions.save(try XCTUnwrap(ProbePanelSession(cookie: cookie(), baseURL: baseURL)), instanceID: instance.id, baseURL: baseURL)
        let editor = ProbeInstanceEditorViewController(instance: instance, store: store, service: PrivateProbePreviewService(), sessions: sessions)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let navigation = UINavigationController(rootViewController: editor)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.loadViewIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while editor.navigationItem.rightBarButtonItem?.isEnabled != true, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(editor.tableView(editor.tableView, numberOfRowsInSection: 0), 5)
        let account = editor.tableView(editor.tableView, cellForRowAt: IndexPath(row: 3, section: 0))
        XCTAssertEqual(account.textLabel?.text, "重新登录账户")
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            navigation.view.frame = window.bounds
            navigation.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: navigation.view.bounds).image { _ in
                navigation.view.drawHierarchy(in: navigation.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 20_000)
            let attachment = XCTAttachment(image: image)
            attachment.name = style == .light ? "private-probe-light" : "private-probe-dark"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        editor.tableView(editor.tableView, didSelectRowAt: IndexPath(row: 4, section: 0))
        XCTAssertNil(sessions.session(instanceID: instance.id, baseURL: baseURL))
        XCTAssertNil(store.snapshot(for: instance.id))
    }

    private func makeService(sessions: ProbeSessionStoring) throws -> ProbeService {
        PrivateProbeURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivateProbeURLProtocol.self]
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "probe-adapter-monitor", withExtension: "json"))
        let registry = ProbeAdapterRegistry(engines: [try ProbeAdapterEngine(data: Data(contentsOf: url))])
        return ProbeService(registry: registry, session: session, sessions: sessions)
    }
}

private actor PrivateProbePreviewService: ProbeFetching {
    var snapshotCalls = 0
    func testConnection(baseURL: URL, adapterID: String) async throws -> ProbeConnectionInfo {
        ProbeConnectionInfo(version: nil, nodes: [ProbeNode(id: "1", name: "Private server", weight: 0)])
    }
    func snapshot(for instance: ProbeInstance, reloadNodes: Bool) async throws -> ProbeSnapshot {
        snapshotCalls += 1
        return ProbeSnapshot(nodes: [], statuses: [:], fetchedAt: Date())
    }
    func history(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeHistoryPoint] { [] }
    func forget(instanceID: UUID) async {}
}

nonisolated final class TestProbeSessions: ProbeSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ProbePanelSession] = [:]
    func session(instanceID: UUID, baseURL: URL) -> ProbePanelSession? {
        lock.lock(); defer { lock.unlock() }
        return values[instanceID.uuidString + baseURL.absoluteString]
    }
    func save(_ session: ProbePanelSession, instanceID: UUID, baseURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        values[instanceID.uuidString + baseURL.absoluteString] = session
    }
    func remove(instanceID: UUID, baseURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        values[instanceID.uuidString + baseURL.absoluteString] = nil
    }
}

private final class PrivateProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let authorized = request.value(forHTTPHeaderField: "Cookie") == "monitor_session=test-session"
        let body: String
        if !authorized { body = #"{"error":"需要登录后查看"}"# }
        else if request.url?.path.contains("metrics") == true { body = #"{"metrics":[{"ts":1700000000,"cpu":30}]}"# }
        else { body = #"{"nodes":[{"id":1,"name":"Private server","online":true,"metrics":{"cpu":10}}]}"# }
        let response = HTTPURLResponse(url: request.url!, statusCode: authorized ? 200 : 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
