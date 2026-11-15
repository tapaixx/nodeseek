import XCTest
import UIKit
@testable import nodeseek

@MainActor
final class ProbeNetworkServiceTests: XCTestCase {
    func testPrivateNetworkHistoryUsesSessionAndCannotReadCachedDataAfterLogout() async throws {
        let base = URL(string: "https://private.example.com")!
        var instance = ProbeInstance(name: "Private", baseURL: base, adapterID: "monitor")
        instance.requiresAuthentication = true
        let sessions = TestProbeSessions()
        let cookie = HTTPCookie(properties: [.name: "monitor_session", .value: "test-session", .domain: "private.example.com", .path: "/", .secure: "TRUE"])!
        try sessions.save(try XCTUnwrap(ProbePanelSession(cookie: cookie, baseURL: base)), instanceID: instance.id, baseURL: base)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeNetworkURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ProbeNetworkURLProtocol.requests = []
        let service = ProbeService(session: session, sessions: sessions)
        let first = try await service.networkHistory(for: instance, nodeID: "1", hours: 6)
        XCTAssertEqual(first.first?.loss, 6.25)
        _ = try await service.networkHistory(for: instance, nodeID: "1", hours: 6)
        XCTAssertEqual(ProbeNetworkURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(ProbeNetworkURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "monitor_session=test-session")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "series" })?.value, "ping")
        XCTAssertEqual(query?.first(where: { $0.name == "hours" })?.value, "6")
        await service.forget(instanceID: instance.id)
        _ = try await service.networkHistory(for: instance, nodeID: "1", hours: 6)
        XCTAssertEqual(ProbeNetworkURLProtocol.requests.count, 2)
        try sessions.remove(instanceID: instance.id, baseURL: base)
        do {
            _ = try await service.networkHistory(for: instance, nodeID: "1", hours: 6)
            XCTFail("Expected expired login to reject cached private data")
        } catch { XCTAssertEqual(error as? ProbeFetchError, .unauthorized) }
        XCTAssertEqual(ProbeNetworkURLProtocol.requests.count, 2)
    }

    func testServerDetailNetworkLayoutAndTaskSelectionInBothThemes() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let store = ProbeInstanceStore(defaults: defaults)
            let instance = ProbeInstance(name: "极简探针", baseURL: URL(string: "https://panel.example.com")!, adapterID: "monitor")
            store.upsert(instance)
            let service = ProbeNetworkPreviewService()
            let model = ProbeMonitorViewModel(store: store, service: service)
            await model.refresh()
            let entry = try XCTUnwrap(model.entries.first)
            let controller = ProbeServerDetailViewController(entryID: entry.id, viewModel: model)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            let navigation = UINavigationController(rootViewController: controller)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            for _ in 0..<200 {
                if find(in: controller.view, id: "probe-network-task-3") != nil { break }
                await Task.yield()
            }
            navigation.view.frame = window.bounds
            navigation.view.layoutIfNeeded()
            let panel = try XCTUnwrap(find(in: controller.view, id: "probe-network-panel"))
            let scroll = try XCTUnwrap(controller.view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView)
            scroll.scrollRectToVisible(panel.convert(panel.bounds, to: scroll), animated: false)
            navigation.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: navigation.view.bounds).image { _ in navigation.view.drawHierarchy(in: navigation.view.bounds, afterScreenUpdates: true) }
            XCTAssertGreaterThan(image.pngData()?.count ?? 0, 20_000)
            let attachment = XCTAttachment(image: image)
            attachment.name = style == .light ? "probe-network-light" : "probe-network-dark"
            attachment.lifetime = .keepAlways
            add(attachment)
            controller.view.layoutIfNeeded()
            scroll.layoutIfNeeded()
            let top = panel.convert(panel.bounds, to: scroll).minY - 12
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, top))), animated: false)
            navigation.view.layoutIfNeeded()
            let focused = UIGraphicsImageRenderer(bounds: navigation.view.bounds).image { _ in navigation.view.drawHierarchy(in: navigation.view.bounds, afterScreenUpdates: true) }
            let focusedAttachment = XCTAttachment(image: focused)
            focusedAttachment.name = style == .light ? "probe-network-focused-light" : "probe-network-focused-dark"
            focusedAttachment.lifetime = .keepAlways
            add(focusedAttachment)
            let task = try XCTUnwrap(find(in: controller.view, id: "probe-network-task-2") as? UIButton)
            task.sendActions(for: .touchUpInside)
            XCTAssertTrue(task.accessibilityLabel?.contains("联通") == true)
            let missing = try XCTUnwrap(find(in: controller.view, id: "probe-network-task-3") as? UIButton)
            XCTAssertTrue(missing.accessibilityLabel?.contains("—") == true)
            window.isHidden = true
            model.stopAutoRefresh()
        }
    }
    private func find(in view: UIView, id: String) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { self.find(in: $0, id: id) }.first
    }
}

private final class ProbeNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let body = #"{"metrics":[],"probes":{"1":"电信","2":"联通","3":"移动"},"ping":[{"task_id":1,"ts":1763193600,"latency":42}],"loss":{"1":6.25},"step":60}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ProbeNetworkPreviewService: ProbeFetching {
    func testConnection(baseURL: URL, adapterID: String) async throws -> ProbeConnectionInfo { ProbeConnectionInfo(version: nil, nodes: []) }
    func snapshot(for instance: ProbeInstance, reloadNodes: Bool) async throws -> ProbeSnapshot {
        ProbeSnapshot(nodes: [ProbeNode(id: "1", name: "洛杉矶 · VPS", cpuCores: 2, weight: 0)], statuses: ["1": ProbeStatus(nodeID: "1", online: true, sampledAt: Date(), metrics: ProbeMetrics(cpuPercent: 12))], fetchedAt: Date())
    }
    func history(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeHistoryPoint] { [] }
    func networkHistory(for instance: ProbeInstance, nodeID: String, hours: Int) async throws -> [ProbeNetworkSeries] {
        let now = Date()
        var points: [ProbeNetworkPoint] = []
        for index in 0..<12 {
            let date = now.addingTimeInterval(Double(index - 11) * 300)
            let latency: Double? = index == 6 ? nil : Double(35 + (index % 4) * 5)
            let loss: Double = index == 6 ? 100 : 0
            points.append(ProbeNetworkPoint(date: date, latency: latency, loss: loss))
        }
        return [ProbeNetworkSeries(id: "1", name: "电信 · 上海", points: points, latency: 45, loss: 6.25, hasSamples: true, latencyScope: "median"),
                ProbeNetworkSeries(id: "2", name: "联通 · 北京", points: points, latency: 38, loss: 0, hasSamples: true, latencyScope: "median"),
                ProbeNetworkSeries(id: "3", name: "移动 · 广州", hasSamples: false)]
    }
    func forget(instanceID: UUID) async {}
}
