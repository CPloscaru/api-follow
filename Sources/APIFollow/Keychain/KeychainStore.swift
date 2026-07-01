import Foundation
import Security

/// Wraps macOS Keychain access for Admin/API keys. Design doc Premise #5:
/// keys are high-privilege secrets and must never land in plaintext config
/// or alongside the SQLite history store.
struct KeychainStore {
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case unexpectedData
    }

    private let service: String

    init(service: String = "com.apifollow.app") {
        self.service = service
    }

    /// `label` allows multiple keys per provider (Success Criteria: v1
    /// supports multiple keys per provider from the start). Defaults to
    /// "default" for the common single-key case.
    private func account(for provider: Provider, label: String) -> String {
        "\(provider.rawValue).\(label)"
    }

    func save(_ secret: String, for provider: Provider, label: String = "default") throws {
        let account = account(for: provider, label: label)
        let data = Data(secret.utf8)

        // Delete any existing item first — SecItemAdd fails on duplicates,
        // and this keeps save() idempotent (re-saving to rotate a key
        // shouldn't require a separate delete-then-save call site).
        try? delete(for: provider, label: label)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns `nil` if no key is stored for this provider/label — this is
    /// an expected, non-error state (e.g. provider not yet configured),
    /// not something callers should have to catch.
    func read(for provider: Provider, label: String = "default") throws -> String? {
        let account = account(for: provider, label: label)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Idempotent — deleting a non-existent item is not an error, since
    /// callers (including `save`) may call this speculatively.
    func delete(for provider: Provider, label: String = "default") throws {
        let account = account(for: provider, label: label)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// All labels currently stored for a provider (multi-key support).
    /// Best-effort — Keychain doesn't support prefix queries directly, so
    /// this scans all items for this service and filters client-side.
    func labels(for provider: Provider) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else { return [] }
            let prefix = "\(provider.rawValue)."
            return items.compactMap { item -> String? in
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix(prefix) else { return nil }
                return String(account.dropFirst(prefix.count))
            }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
