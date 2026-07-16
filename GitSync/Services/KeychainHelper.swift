import Foundation
import Security

/// 极简 Keychain 封装，只存/取/删 一个字符串（GitHub PAT）
enum KeychainHelper {
    private static func service(for id: UUID) -> String {
        "com.shai.gitsync.pat.\(id.uuidString)"
    }

    static func saveToken(_ token: String, forConfigId id: UUID) {
        let service = service(for: id)
        let data = Data(token.utf8)

        // 先删掉旧的，再插入，避免重复 item 报错
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func loadToken(forConfigId id: UUID) -> String? {
        let service = service(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(forConfigId id: UUID) {
        let service = service(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
