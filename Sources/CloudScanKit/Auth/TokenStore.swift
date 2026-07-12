//
//  TokenStore.swift
//  Neodisk
//
//  Persistence for a connected account's OAuth credentials, keyed by
//  (providerID, accountID). The Keychain implementation is the only place
//  refresh tokens are written; the in-memory one keeps them off the Keychain
//  in unit tests. The protocol is synchronous because CloudProvider's
//  restoreAccounts() runs at launch, before the snapshot-cache prune.
//

import Foundation
import Security

/// What is persisted per connected account. The refresh token is the durable
/// secret; the access token is a short-lived cache refreshed on demand.
public struct StoredCredentials: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var accessToken: String?
    public var accessTokenExpiry: Date?
    public var email: String?

    public init(
        refreshToken: String,
        accessToken: String? = nil,
        accessTokenExpiry: Date? = nil,
        email: String? = nil
    ) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.email = email
    }
}

public protocol TokenStoring: Sendable {
    func save(_ credentials: StoredCredentials, forProviderID providerID: String, accountID: String) throws
    func load(forProviderID providerID: String, accountID: String) throws -> StoredCredentials?
    func delete(forProviderID providerID: String, accountID: String) throws
    func accountIDs(forProviderID providerID: String) throws -> [String]
}

public enum TokenStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case decodingFailed
}

/// Generic-password Keychain storage. One item per account: service
/// "app.neodisk.cloudscan.<providerID>", account = accountID, value = the
/// JSON-encoded credentials. Never exercised in unit tests.
public struct KeychainTokenStore: TokenStoring {
    private static let servicePrefix = "app.neodisk.cloudscan."

    public init() {}

    private func service(_ providerID: String) -> String {
        Self.servicePrefix + providerID
    }

    public func save(
        _ credentials: StoredCredentials,
        forProviderID providerID: String,
        accountID: String
    ) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(providerID),
            kSecAttrAccount as String: accountID
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
            return
        }
        throw TokenStoreError.keychain(updateStatus)
    }

    public func load(
        forProviderID providerID: String,
        accountID: String
    ) throws -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(providerID),
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let data = item as? Data else { throw TokenStoreError.decodingFailed }
        return try JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    public func delete(forProviderID providerID: String, accountID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(providerID),
            kSecAttrAccount as String: accountID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }

    public func accountIDs(forProviderID providerID: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(providerID),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let entries = items as? [[String: Any]] else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// A lock-guarded in-memory store for tests. (A synchronous `TokenStoring` —
/// required because `restoreAccounts()` is synchronous — cannot be satisfied
/// by an `actor`, whose members are async, so this uses a lock instead.)
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [String: StoredCredentials]] = [:]

    public init() {}

    public func save(
        _ credentials: StoredCredentials,
        forProviderID providerID: String,
        accountID: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[providerID, default: [:]][accountID] = credentials
    }

    public func load(forProviderID providerID: String, accountID: String) throws -> StoredCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID]?[accountID]
    }

    public func delete(forProviderID providerID: String, accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[providerID]?[accountID] = nil
    }

    public func accountIDs(forProviderID providerID: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage[providerID].map { Array($0.keys) } ?? []
    }
}
