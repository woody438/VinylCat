import Foundation
import Security

/// API keys and the Discogs token, in a mode-0600 JSON file next to the database:
/// `~/Library/Application Support/VinylCat/keys.json`.
///
/// They used to live in the login keychain, which pins every item to the code hash of the build
/// that stored it (the `partition_id` ACL entry, macOS 10.12+). Without an Apple team identity
/// there is no way to widen that — "allow all applications" only covers the application list, and
/// the entry cannot be stripped without the same dialog — so every rebuild brought the "VinylCat
/// wants to use your confidential information" prompt back, once per key, on the app *and* on the
/// headless harnesses. A 0600 file is readable by anything running as this user, which is exactly
/// the footing an "allow all applications" item would have had, and it never prompts.
enum Secrets {
    enum Key: String, CaseIterable {
        case openAI = "openai-api-key"
        case gemini = "gemini-api-key"
        /// Optional for the Claude reader — a short-lived OAuth or federated token is preferred
        /// when one is available (`AnthropicCredential`).
        case anthropic = "anthropic-api-key"
        case discogsToken = "discogs-token"
    }

    /// `VINYLCAT_NO_KEYCHAIN=1` makes every key read as missing: `--scenario` then runs OCR-only.
    static let disabled = ProcessInfo.processInfo.environment["VINYLCAT_NO_KEYCHAIN"] != nil

    static let fileURL: URL = PhotoStore.shared.root.deletingLastPathComponent().appendingPathComponent("keys.json")
    private static let legacyService = "com.woodall.vinylcat"

    static func get(_ key: Key) -> String? {
        if disabled { return nil }
        if let v = load()[key.rawValue]?.nilIfEmpty { return v }
        // First launch since the move: lift it out of the keychain (one last dialog) and keep it here.
        guard let v = legacyRead(key) else { return nil }
        set(v, for: key)
        legacyDelete(key)
        return v
    }

    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = load()
        if trimmed.isEmpty { all[key.rawValue] = nil } else { all[key.rawValue] = trimmed }
        return save(all)
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        legacyDelete(key)
        return set("", for: key)
    }

    // MARK: - File

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save(_ all: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(all)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            Log.scan.error("keys.json write failed: \(error)")
            return false
        }
    }

    // MARK: - Legacy keychain items (read once to migrate, then removed)

    private static func legacyRead(_ key: Key) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func legacyDelete(_ key: Key) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Old name, kept so call sites read the same.
typealias Keychain = Secrets
