import Foundation
import WebKit

@MainActor
final class TradeLiveEvents {
    static let didReceive = Notification.Name("TradeLiveEvents.didReceive")
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    func start(conversationID: Int64? = nil) {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var request = URLRequest(url: URL(string: "wss://agent-api.nodeseek.org/ws")!)
                request.setValue("https://agent.nodeseek.org", forHTTPHeaderField: "Origin")
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter {
                    ["agent-api.nodeseek.org", ".agent-api.nodeseek.org", ".nodeseek.org"].contains($0.domain.lowercased())
                        && ($0.expiresDate.map { $0 > Date() } ?? true) && $0.path == "/"
                }
                for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                let session = URLSession(configuration: configuration, delegate: TradeRedirectPolicy(), delegateQueue: nil)
                self.session = session
                let socket = session.webSocketTask(with: request)
                self.socket = socket
                socket.resume()
                do {
                    if let conversationID {
                        let data = try JSONSerialization.data(withJSONObject: ["type": "subscribe", "conversation_id": conversationID])
                        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    }
                    NotificationCenter.default.post(name: Self.didReceive, object: nil)
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        guard data.count < 256 * 1024, let event = try? JSONDecoder().decode(TradeValue.self, from: data) else { continue }
                        failures = 0
                        NotificationCenter.default.post(name: Self.didReceive, object: nil, userInfo: ["event": event])
                    }
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    session.invalidateAndCancel()
                    if Task.isCancelled { return }
                    failures = min(failures + 1, 4)
                    do { try await Task.sleep(nanoseconds: UInt64(min(15, 1 << failures)) * 1_000_000_000) } catch { return }
                }
            }
        }
    }
    func stop() {
        worker?.cancel(); worker = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
    deinit { worker?.cancel(); socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel() }
}
