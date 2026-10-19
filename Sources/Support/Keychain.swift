import Foundation
import Security

/// Keychain storage for the two secrets Snag holds: the Anthropic API key and a Jira
/// API token per board.
///
/// The brief is explicit that the API key must never land in `UserDefaults` or a file,
/// and that's the right call -- `AppSettings` is a plain JSON blob in a readable plist,
/// and the capture library is an ordinary folder. Nothing secret goes in either.
enum Keychain {
    private static let service = "dev.snag.Snag"

    enum Account {
        static let anthropicAPIKey = "anthropic-api-key"
        /// Scoped per board, since each may point at a different Jira site.
        static func jiraToken(boardID: UUID) -> String { "jira-token:\(boardID.uuidString)" }
    }

    enum Failure: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    // MARK: - Reading

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfEmpty
    }

    static func has(account: String) -> Bool {
        read(account: account) != nil
    }

    // MARK: - Writing

    /// Writes, or removes the item when `value` is nil or blank. Updates in place when
    /// an item already exists rather than duplicating it.
    static func write(_ value: String?, account: String) throws {
        guard let value = value?.nilIfEmpty else {
            try delete(account: account)
            return
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Failure.unexpectedStatus(updateStatus)
        }

        var insert = base
        insert[kSecValueData as String] = data
        // The app is a login-item agent, so the key must be readable after unlock
        // without the user being present.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }
}
