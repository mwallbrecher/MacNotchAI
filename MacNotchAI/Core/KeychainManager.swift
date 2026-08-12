import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()
    private init() {}

    /// Insert or replace a generic-password value without deleting a working value
    /// before its replacement has been accepted by Security.framework.
    ///
    /// The return value matters for callers that persist non-secret metadata beside
    /// a Keychain secret: they must never advertise a record whose secret failed to
    /// save. Existing API-key callers may continue to ignore it.
    @discardableResult
    func save(key: String, service: String) -> Bool {
        guard !service.isEmpty, let data = key.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let added = query.merging([kSecValueData as String: data]) { _, new in new }
        let addStatus = SecItemAdd(added as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }

        let attributes = [kSecValueData as String: data]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
    }

    func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
