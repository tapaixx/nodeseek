import Foundation
import Security

nonisolated struct ProbePanelSession: Codable, Equatable, Sendable {
    let value: String
    let expiresAt: Date?

    init?(cookie: HTTPCookie, baseURL: URL) {
        guard cookie.name == "monitor_session", cookie.isSecure,
              cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == baseURL.host?.lowercased(),
              cookie.path == "/" else { return nil }
        value = cookie.value
        expiresAt = cookie.expiresDate
        guard header() != nil else { return nil }
    }

    func header(now: Date = Date()) -> String? {
        guard !value.isEmpty, expiresAt.map({ $0 > now }) ?? true,
              value.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: ";,"))) == nil else { return nil }
        return "monitor_session=\(value)"
    }
}

nonisolated protocol ProbeSessionStoring: Sendable {
    func session(instanceID: UUID, baseURL: URL) -> ProbePanelSession?
    func save(_ session: ProbePanelSession, instanceID: UUID, baseURL: URL) throws
    func remove(instanceID: UUID, baseURL: URL) throws
}

nonisolated final class KeychainProbeSessionStore: ProbeSessionStoring, @unchecked Sendable {
    static let shared = KeychainProbeSessionStore()
    private let service: String

    init(service: String = "com.nodeseek.probe-session") { self.service = service }

    func session(instanceID: UUID, baseURL: URL) -> ProbePanelSession? {
        var query = query(instanceID, baseURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let session = try? JSONDecoder().decode(ProbePanelSession.self, from: data),
              session.header() != nil else { return nil }
        return session
    }

    func save(_ session: ProbePanelSession, instanceID: UUID, baseURL: URL) throws {
        guard session.header() != nil else { throw ProbeFetchError.unauthorized }
        let data = try JSONEncoder().encode(session)
        var query = query(instanceID, baseURL)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProbeCredentialError.unavailable }
    }

    func remove(instanceID: UUID, baseURL: URL) throws {
        let status = SecItemDelete(query(instanceID, baseURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProbeCredentialError.unavailable }
    }

    private func query(_ id: UUID, _ baseURL: URL) -> [String: Any] {
        let origin = ProbeAdapterEngine.normalizedBaseURL(baseURL.absoluteString)?.absoluteString ?? baseURL.absoluteString
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(id.uuidString)|\(origin)"]
    }
}

enum ProbeCredentialError: LocalizedError {
    case unavailable
    var errorDescription: String? { "无法更新本机保存的登录状态，请重试" }
}
