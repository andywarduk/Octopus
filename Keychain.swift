// The API key lives in the login Keychain, not in UserDefaults.

import Foundation
import Security

enum Keychain {
    static let service = "OctopusMenuBar"
    static let account = "api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Updates an existing item in place, or adds one. Updating rather than delete-then-add means a
    /// failure can't leave the keychain with no key at all. Returns errSecSuccess or the failure.
    static func save(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated != errSecItemNotFound { return updated }
        var item = base
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    @discardableResult
    static func delete() -> OSStatus {
        SecItemDelete(base as CFDictionary)
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
