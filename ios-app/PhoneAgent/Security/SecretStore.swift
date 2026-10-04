import Foundation
import Security

enum SecretStore {
    private static let service = "dev.dotprototype.PhoneAgent"
    static func load(_ account: String) throws -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AppError.unavailable("无法读取钥匙串（\(status)）") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw AppError.invalid("无效密钥") }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account); attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AppError.unavailable("无法保存到钥匙串") }
        } else if status != errSecSuccess { throw AppError.unavailable("无法更新钥匙串（\(status)）") }
    }
    static func delete(_ account: String) throws {
        let s = SecItemDelete(query(account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw AppError.unavailable("无法删除密钥（\(s)）") }
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
