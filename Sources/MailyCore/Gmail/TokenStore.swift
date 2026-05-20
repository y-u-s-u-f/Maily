import Foundation
import Security

/// Persists OAuth refresh tokens keyed by account email.
///
/// Refresh tokens are long-lived and treated as the user's most sensitive
/// credential after their password — they're the only thing stored on disk
/// (access tokens stay in memory).
public protocol TokenStore: Sendable {
    func saveRefreshToken(_ token: String, account: String) throws
    func loadRefreshToken(account: String) throws -> String?
    func deleteRefreshToken(account: String) throws
}

public enum TokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidTokenData
}

// MARK: - Keychain implementation

/// macOS Keychain-backed `TokenStore`. One generic password item per account.
///
/// `service` defaults to `dev.yusuf.maily.gmail` in production. Tests pass a
/// per-run UUID service to stay isolated from the developer's real Keychain.
///
/// Access groups (per the Maily plan, `dev.yusuf.maily`) require code-signing
/// entitlements that aren't wired up yet. They're left optional here so the
/// app works under `swift run` during development; we promote to a real access
/// group once the app target is signed.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "dev.yusuf.maily.gmail", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    public func saveRefreshToken(_ token: String, account: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.invalidTokenData
        }

        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw TokenStoreError.unexpectedStatus(updateStatus)
        }
    }

    public func loadRefreshToken(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.invalidTokenData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.unexpectedStatus(status)
        }
    }

    public func deleteRefreshToken(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw TokenStoreError.unexpectedStatus(status)
        }
    }
}

// MARK: - In-memory implementation (tests)

/// Process-local `TokenStore` used in unit tests so we never touch the real
/// Keychain. Thread-safe via an internal lock.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    public init() {}

    public func saveRefreshToken(_ token: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        tokens[account] = token
    }

    public func loadRefreshToken(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[account]
    }

    public func deleteRefreshToken(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        tokens.removeValue(forKey: account)
    }
}
