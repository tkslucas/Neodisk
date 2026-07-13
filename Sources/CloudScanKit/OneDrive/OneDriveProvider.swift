//
//  OneDriveProvider.swift
//  Neodisk
//
//  The OneDrive (personal) CloudProvider, backed by Microsoft Graph.
//  authorize() runs the loopback PKCE flow, reads the account identity from
//  Graph's /me endpoint, and persists credentials; enumeration walks the
//  drive's delta feed. Microsoft rotates the refresh token on every refresh,
//  which TokenBroker already persists back through the token store.
//
//  Sizes need care: Graph reports `size` on FOLDERS as an aggregate of their
//  descendants. Keeping those would double-count against the children the tree
//  builder rolls up, so folders are mapped with no size and the builder
//  derives folder totals from their contents (matching the Google provider).
//

import Foundation
import NeodiskKit

public struct OneDriveProvider: CloudProvider {
    public let providerID = "onedrive"
    public let displayName = "OneDrive"

    private let configuration: OneDriveOAuthConfiguration
    private let transport: any CloudTransport
    private let tokenStore: any TokenStoring

    private static let identityEndpoint =
        URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName")!
    private static let quotaEndpoint =
        URL(string: "https://graph.microsoft.com/v1.0/me/drive?$select=quota")!
    private static let rootEndpoint =
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/root?$select=id")!
    private static let deltaEndpoint =
        URL(string: "https://graph.microsoft.com/v1.0/me/drive/root/delta?$select=id,name,size,parentReference,file,folder,package,deleted,lastModifiedDateTime")!

    public init(
        configuration: OneDriveOAuthConfiguration,
        transport: any CloudTransport,
        tokenStore: any TokenStoring
    ) {
        self.configuration = configuration
        self.transport = transport
        self.tokenStore = tokenStore
    }

    // MARK: - Authorization

    public func authorize(
        openURL: @Sendable @escaping (URL) -> Void
    ) async throws -> CloudAccount {
        guard configuration.isConfigured else {
            throw OneDriveError.notConfigured
        }

        let authorizer = OAuthAuthorizer(configuration: configuration.oauthClient, transport: transport)
        let tokens = try await authorizer.authorize(openURL: openURL)

        let identity = try await fetchIdentity(accessToken: tokens.accessToken)
        guard let refreshToken = tokens.refreshToken else {
            // offline_access should always return one; guard anyway.
            throw OneDriveError.missingRefreshToken
        }

        let email = identity.mail ?? identity.userPrincipalName
        let credentials = StoredCredentials(
            refreshToken: refreshToken,
            accessToken: tokens.accessToken,
            accessTokenExpiry: tokens.expiryDate,
            email: email
        )
        try tokenStore.save(credentials, forProviderID: providerID, accountID: identity.id)

        return CloudAccount(
            providerID: providerID,
            accountID: identity.id,
            email: email ?? identity.id
        )
    }

    public func restoreAccounts() throws -> [CloudAccount] {
        let ids = try tokenStore.accountIDs(forProviderID: providerID)
        return try ids.compactMap { accountID in
            guard let credentials = try tokenStore.load(
                forProviderID: providerID, accountID: accountID
            ) else { return nil }
            return CloudAccount(
                providerID: providerID,
                accountID: accountID,
                email: credentials.email ?? accountID
            )
        }
    }

    public func signOut(_ account: CloudAccount) async throws {
        // Microsoft has no public-client revocation endpoint, so sign-out just
        // drops the stored credentials (revokeEndpoint is nil → revoke is a
        // no-op even if called).
        try tokenStore.delete(forProviderID: providerID, accountID: account.accountID)
    }

    // MARK: - Enumeration

    public func quota(for account: CloudAccount) async throws -> CloudQuota {
        let data = try await makeClient(for: account).get(Self.quotaEndpoint)
        let quota = try JSONDecoder().decode(DriveResponseDTO.self, from: data).quota
        // Graph reports total 0 (or omits it) for unlimited/unknown; treat that
        // as no ceiling. OneDrive has no Gmail/Photos-style split, so the
        // account-wide figure is the same as the drive usage.
        let total = quota?.total
        return CloudQuota(
            totalBytes: (total ?? 0) > 0 ? total : nil,
            usedBytes: quota?.used ?? 0,
            accountUsedBytes: quota?.used ?? 0
        )
    }

    public func rootFolderID(for account: CloudAccount) async throws -> String {
        let data = try await makeClient(for: account).get(Self.rootEndpoint)
        return try JSONDecoder().decode(DriveItemDTO.self, from: data).id
    }

    public func listAllFiles(
        for account: CloudAccount
    ) -> AsyncThrowingStream<[CloudFileEntry], Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let client = self.makeClient(for: account)
                    var url: URL? = Self.deltaEndpoint
                    while let pageURL = url {
                        try Task.checkCancellation()
                        let data = try await client.get(pageURL)
                        let page = try JSONDecoder().decode(DeltaPageDTO.self, from: data)
                        continuation.yield((page.value ?? []).compactMap(Self.entry(from:)))
                        // A page carrying @odata.deltaLink is the last one; the
                        // deltaLink is a resumption cursor for future syncs, not
                        // another page to fetch, so stop rather than follow it.
                        if page.deltaLink != nil {
                            url = nil
                        } else if let next = page.nextLink {
                            url = URL(string: next)
                        } else {
                            url = nil
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request plumbing

    private var authorizer: OAuthAuthorizer {
        OAuthAuthorizer(configuration: configuration.oauthClient, transport: transport)
    }

    private func makeClient(for account: CloudAccount) -> GraphAPIClient {
        let broker = TokenBroker(
            providerID: providerID,
            accountID: account.accountID,
            authorizer: authorizer,
            tokenStore: tokenStore
        )
        return GraphAPIClient(transport: transport, broker: broker)
    }

    // MARK: - Mapping

    /// Maps one delta item to an entry, or nil for a tombstone (an item with a
    /// `deleted` facet, which the delta feed emits for removed items).
    static func entry(from dto: DriveItemDTO) -> CloudFileEntry? {
        if dto.deleted != nil { return nil }

        // A `package` (e.g. a OneNote notebook) is a folder-like container, so
        // it and true folders are both treated as folders.
        let isFolder = dto.folder != nil || dto.package != nil
        // Folder `size` is an aggregate of descendants; keeping it would
        // double-count against the children the builder rolls up, so folders
        // carry no size and the builder derives their totals.
        let logicalBytes = isFolder ? nil : dto.size
        let quotaBytes = isFolder ? nil : dto.size

        return CloudFileEntry(
            id: dto.id,
            name: dto.name ?? dto.id,
            parentID: dto.parentReference?.id,
            isFolder: isFolder,
            logicalBytes: logicalBytes,
            quotaBytes: quotaBytes,
            modifiedAt: dto.lastModifiedDateTime.flatMap(parseISO8601),
            contentHash: dto.file?.hashes?.quickXorHash ?? dto.file?.hashes?.sha256Hash,
            kindHint: dto.file?.mimeType,
            isOwnedByMe: true
        )
    }

    /// Graph stamps timestamps as ISO8601, usually with fractional seconds
    /// ("…T…​.123Z") but tolerate the whole-second form too.
    static func parseISO8601(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601Whole.date(from: string)
    }

    // Read-only after construction; ISO8601DateFormatter parsing is
    // thread-safe as long as the format options aren't mutated.
    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601Whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Identity

    private func fetchIdentity(accessToken: String) async throws -> MeDTO {
        var request = URLRequest(url: Self.identityEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.execute(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OneDriveError.identityFetchFailed(status: response.statusCode)
        }
        return try JSONDecoder().decode(MeDTO.self, from: data)
    }
}

public enum OneDriveError: Error, Equatable, Sendable {
    case notConfigured
    case missingRefreshToken
    case identityFetchFailed(status: Int)
    /// A non-retryable API error, carrying Graph's own error message.
    case requestFailed(status: Int, message: String?)
}

extension OneDriveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OneDrive isn't set up in this build of Neodisk yet."
        case .missingRefreshToken:
            return "Microsoft did not return a refresh token. Try connecting again."
        case .identityFetchFailed(let status):
            return "Could not read your Microsoft account details (HTTP \(status))."
        case .requestFailed(let status, let message):
            if let message {
                return "OneDrive request failed (HTTP \(status)): \(message)"
            }
            return "OneDrive request failed (HTTP \(status))."
        }
    }
}

// MARK: - Identity DTOs

private struct MeDTO: Decodable {
    let id: String
    let mail: String?
    let userPrincipalName: String?
}

// MARK: - Enumeration DTOs

private struct DriveResponseDTO: Decodable {
    let quota: QuotaDTO?
}

private struct QuotaDTO: Decodable {
    let total: Int64?
    let used: Int64?
}

/// One page of the drive delta feed. Both continuation links arrive as
/// OData annotations with an `@odata.` prefix, which isn't a legal Swift
/// identifier, so they are decoded through explicit coding keys.
struct DeltaPageDTO: Decodable {
    let value: [DriveItemDTO]?
    /// Present on every page but the last: the URL of the next page.
    let nextLink: String?
    /// Present only on the final page: a resumption cursor, never followed.
    let deltaLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

struct DriveItemDTO: Decodable {
    let id: String
    let name: String?
    let size: Int64?
    let parentReference: ParentReferenceDTO?
    let file: FileFacetDTO?
    let folder: FolderFacetDTO?
    let package: PackageFacetDTO?
    let deleted: DeletedFacetDTO?
    let lastModifiedDateTime: String?
}

struct ParentReferenceDTO: Decodable {
    let id: String?
}

struct FileFacetDTO: Decodable {
    let mimeType: String?
    let hashes: HashesDTO?
}

struct HashesDTO: Decodable {
    let quickXorHash: String?
    let sha256Hash: String?
}

struct FolderFacetDTO: Decodable {}

struct PackageFacetDTO: Decodable {}

struct DeletedFacetDTO: Decodable {}
