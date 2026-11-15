import XCTest
@testable import nodeseek

@MainActor
final class DirectPushSenderTests: XCTestCase {
    func testDirectBarkHTTPUsesNoCookiesAndChecksBusinessResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectPushTestURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let sender = DirectPushSender(session: session)
        let settings = DirectPushConfiguration(channel: .bark, address: "https://bark.example.com/prefix/fake-device")
        let event = DirectPushEvent(id: "test", title: "test", body: "test", type: "message", url: nil, date: Date())
        DirectPushTestURLProtocol.body = #"{"code":200}"#
        DirectPushTestURLProtocol.calls = 0
        try await sender.send(event, configuration: settings)
        XCTAssertEqual(DirectPushTestURLProtocol.last?.url?.path, "/prefix/push")
        XCTAssertNil(DirectPushTestURLProtocol.last?.value(forHTTPHeaderField: "Cookie"))
        DirectPushTestURLProtocol.body = #"{"code":400,"message":"fake-device"}"#
        do {
            try await sender.send(event, configuration: settings)
            XCTFail("Expected failed business response")
        } catch {
            XCTAssertEqual(error as? DirectPushError, .rejected(400))
            XCTAssertFalse(error.localizedDescription.contains("fake-device"))
        }
        XCTAssertEqual(DirectPushTestURLProtocol.calls, 2)
    }
}

private final class DirectPushTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var last: URLRequest?
    nonisolated(unsafe) static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.last = request; Self.calls += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
