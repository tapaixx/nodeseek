import Foundation

/// 僅保存服務地址；Webhook、Bark Key 與服務密碼由服務端管理。
final class PushRelaySettingsStore {
    static let shared = PushRelaySettingsStore()
    private let defaults: UserDefaults
    private let key = "push.relay.baseURL"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var baseURL: URL? { defaults.string(forKey: key).flatMap(PushRelayAddress.normalized) }
    func save(_ url: URL?) {
        if let url { defaults.set(url.absoluteString, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
