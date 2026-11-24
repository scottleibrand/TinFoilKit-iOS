import Foundation
import Security

enum OnlineAskKeys {
    static func key(for provider: OnlineAskProvider) throws -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeyError() }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ raw: String, for provider: OnlineAskProvider) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = query(provider)
        guard !key.isEmpty else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError() }
            return
        }
        let changes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let update = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeyError() }
        var item = request.merging(changes) { _, new in new }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KeyError() }
    }

    private static func query(_ provider: OnlineAskProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.tinfoilkit.ios.online-ask",
            kSecAttrAccount as String: provider.rawValue
        ]
    }

    private struct KeyError: LocalizedError {
        var errorDescription: String? { "The online provider key could not be accessed in Keychain." }
    }
}
