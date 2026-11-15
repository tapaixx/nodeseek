import UIKit

@MainActor
final class SiteVerificationCoordinator {
    static let shared = SiteVerificationCoordinator()
    static let didChange = Notification.Name("SiteVerification.didChange")
    static let didVerify = Notification.Name("SiteVerification.didVerify")
    private(set) var requiredURL: URL?
    private(set) var isPresenting = false
    var automaticRequestsPaused: Bool { requiredURL != nil || isPresenting }

    func require(_ url: URL) {
        requiredURL = NodeSeekVerificationRequired.safeURL(url)
        changed()
    }
    func record(_ challenge: ChallengeKind) {
        switch challenge {
        case .cloudflare(let url), .blocked(let url): require(url)
        case .loginRequired, .unsupported: break
        }
    }
    func recordSuccess() {
        guard requiredURL != nil, !isPresenting else { return }
        reset()
    }
    func begin() { isPresenting = true; changed() }
    func end() { isPresenting = false; changed() }
    func reset() { requiredURL = nil; isPresenting = false; changed() }
    func verified() {
        reset()
        NotificationCenter.default.post(name: Self.didVerify, object: self)
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    func present(from source: UIViewController, onVerified: @escaping () -> Void = {}) {
        guard !isPresenting, source.viewIfLoaded?.window != nil else { return }
        begin()
        let controller = SiteVerificationViewController(initialURL: requiredURL ?? NodeSeekSite.baseURL, coordinator: self, onVerified: onVerified)
        source.present(MessageNavigationController(rootViewController: controller), animated: true)
    }
}
