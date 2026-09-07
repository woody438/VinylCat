import Foundation
import Security

/// Minimal generic-password Keychain wrapper for API tokens.
enum Keychain {
    private static let service = "com.woodall.vinylcat"

    enum Key: String, CaseIterable {
        case openAI = "openai-api-key"
        case gemini = "gemini-api-key"
        case discogsToken = "discogs-token"
    }

    /// `VINYLCAT_NO_KEYCHAIN=1` makes every key read as missing. For the headless harnesses
    /// (`--render-ui`) that don't need keys: a freshly built binary otherwise blocks on the
    /// Keychain's "allow access?" dialog, which nobody is there to answer.
    static let disabled = ProcessInfo.processInfo.environment["VINYLCAT_NO_KEYCHAIN"] != nil

    static func get(_ key: Key) -> String? {
        if disabled { return nil }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete(key) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let r = SecItemDelete(q as CFDictionary)
        return r == errSecSuccess || r == errSecItemNotFound
    }
}
