import Foundation

nonisolated protocol DirectPushSending: Sendable {
    func send(_ event: DirectPushEvent, configuration: DirectPushConfiguration) async throws
}

actor DirectPushSender: DirectPushSending {
    static let shared = DirectPushSender()
    private let session: URLSession
    private var nextWeCom = Date.distantPast

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: DirectPushRedirectDelegate(), delegateQueue: nil)
        }
    }

    func send(_ event: DirectPushEvent, configuration: DirectPushConfiguration) async throws {
        let request = try DirectPushPayload.request(configuration: configuration, event: event)
        if configuration.channel == .wecom {
            let slot = max(Date(), nextWeCom)
            nextWeCom = slot.addingTimeInterval(3.1)
            let delay = slot.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DirectPushError.uncertain }
        guard let http = response as? HTTPURLResponse else { throw DirectPushError.uncertain }
        try DirectPushPayload.check(data: data, status: http.statusCode, channel: configuration.channel)
    }
}

private final class DirectPushRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
