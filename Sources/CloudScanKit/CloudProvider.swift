//
//  CloudProvider.swift
//  Neodisk
//
//  Provider-agnostic surface for remote cloud drives. Google Drive and
//  Microsoft Graph link files by parent ID; Dropbox lists full paths — a
//  CloudFileEntry carries either linkage and CloudTreeBuilder accepts both.
//  Implementations are UI-free: the OAuth dance receives an openURL closure
//  instead of touching AppKit.
//

import Foundation

/// A connected cloud account, identified by the provider's stable user ID
/// (never the email, which can change).
public struct CloudAccount: Hashable, Codable, Sendable {
    public let providerID: String
    public let accountID: String
    public let email: String

    public init(providerID: String, accountID: String, email: String) {
        self.providerID = providerID
        self.accountID = accountID
        self.email = email
    }
}

public struct CloudQuota: Hashable, Codable, Sendable {
    /// nil for unlimited plans.
    public let totalBytes: Int64?
    public let usedBytes: Int64

    public init(totalBytes: Int64?, usedBytes: Int64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }
}

/// One remote file or folder, as reported by a provider listing.
public struct CloudFileEntry: Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    /// Parent-linkage (Drive, Graph). nil when unknown — the entry is
    /// treated as orphaned unless `pathComponents` locates it.
    public let parentID: String?
    /// Path-linkage (Dropbox): the entry's full path inside the drive,
    /// excluding the drive root itself. Missing intermediate folders are
    /// synthesized.
    public let pathComponents: [String]?
    public let isFolder: Bool
    /// Data length. Provider-native documents may report none.
    public let logicalBytes: Int64?
    /// Bytes counted against the account's quota — what a "why is my drive
    /// full" treemap should size by. nil where the provider has no such
    /// notion (falls back to `logicalBytes`).
    public let quotaBytes: Int64?
    public let modifiedAt: Date?
    /// Provider content hash (e.g. Drive md5Checksum) for future duplicate
    /// detection. Unused today.
    public let contentHash: String?
    /// Provider type hint (e.g. MIME type) for future kind classification.
    public let kindHint: String?
    public let isOwnedByMe: Bool

    public init(
        id: String,
        name: String,
        parentID: String? = nil,
        pathComponents: [String]? = nil,
        isFolder: Bool,
        logicalBytes: Int64? = nil,
        quotaBytes: Int64? = nil,
        modifiedAt: Date? = nil,
        contentHash: String? = nil,
        kindHint: String? = nil,
        isOwnedByMe: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.pathComponents = pathComponents
        self.isFolder = isFolder
        self.logicalBytes = logicalBytes
        self.quotaBytes = quotaBytes
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.kindHint = kindHint
        self.isOwnedByMe = isOwnedByMe
    }

    /// The size the treemap uses.
    public nonisolated var allocatedBytes: Int64 {
        quotaBytes ?? logicalBytes ?? 0
    }

    /// Decode with defaults for the optional-ish fields, so hand-written
    /// fixtures only spell out what they use.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        self.pathComponents = try container.decodeIfPresent([String].self, forKey: .pathComponents)
        self.isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        self.logicalBytes = try container.decodeIfPresent(Int64.self, forKey: .logicalBytes)
        self.quotaBytes = try container.decodeIfPresent(Int64.self, forKey: .quotaBytes)
        self.modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        self.contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        self.kindHint = try container.decodeIfPresent(String.self, forKey: .kindHint)
        self.isOwnedByMe = try container.decodeIfPresent(Bool.self, forKey: .isOwnedByMe) ?? true
    }
}

public protocol CloudProvider: Sendable {
    /// Stable lowercase identifier used in target IDs ("google").
    var providerID: String { get }
    /// User-visible provider name ("Google Drive").
    var displayName: String { get }

    /// Runs the full OAuth flow. `openURL` is supplied by the UI layer so
    /// this package never touches AppKit.
    func authorize(openURL: @Sendable @escaping (URL) -> Void) async throws -> CloudAccount
    /// Accounts with stored credentials (synchronous — read at launch,
    /// before the snapshot-cache prune computes its keep-list).
    func restoreAccounts() throws -> [CloudAccount]
    /// Revokes and deletes the account's stored credentials.
    func signOut(_ account: CloudAccount) async throws
    func quota(for account: CloudAccount) async throws -> CloudQuota
    /// The drive's root container ID, with provider aliases resolved.
    func rootFolderID(for account: CloudAccount) async throws -> String
    /// Enumerates every file and folder, one listing page per element.
    func listAllFiles(for account: CloudAccount) -> AsyncThrowingStream<[CloudFileEntry], Error>
}

public enum CloudScanError: Error, Equatable {
    case invalidTarget(String)
    case accountNotConnected(String)
    case authorizationRequired
    case unsupportedOperation(String)
}

extension CloudScanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTarget(let id):
            return "Not a cloud scan target: \(id)"
        case .accountNotConnected(let id):
            return "This cloud account is no longer connected (\(id)). Reconnect it and scan again."
        case .authorizationRequired:
            return "The cloud account needs to be reauthorized."
        case .unsupportedOperation(let what):
            return "Unsupported cloud operation: \(what)"
        }
    }
}
