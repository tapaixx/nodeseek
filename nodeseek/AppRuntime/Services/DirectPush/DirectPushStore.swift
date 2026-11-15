import Foundation
import Security

@MainActor
protocol DirectPushStoring: AnyObject {
    func configuration(_ channel: DirectPushChannel) -> DirectPushConfiguration?
    func save(_ configuration: DirectPushConfiguration) throws
    func remove(_ channel: DirectPushChannel) throws
}

final class DirectPushStore: DirectPushStoring {
    static let shared = DirectPushStore()
    static let didChange = Notification.Name("DirectPushStore.didChange")
    private let service = "com.nodeseek.direct-push"

    func configuration(_ channel: DirectPushChannel) -> DirectPushConfiguration? {
        var query = query(channel)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(DirectPushConfiguration.self, from: data)
    }

    func save(_ configuration: DirectPushConfiguration) throws {
        _ = try configuration.validatedURL()
        let data = try JSONEncoder().encode(configuration)
        var query = query(configuration.channel)
        let update = [kSecValueData as String: data]
        var result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw DirectPushError.credentials }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func remove(_ channel: DirectPushChannel) throws {
        let result = SecItemDelete(query(channel) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw DirectPushError.credentials }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func query(_ channel: DirectPushChannel) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: channel.rawValue]
    }
}
