//
//  GoogleDriveProvider.swift
//  Neodisk
//
//  The Google Drive CloudProvider. M2 lands the OAuth + identity + credential
//  storage half: authorize() runs the loopback flow, reads the account
//  identity from the Drive `about` endpoint, and persists credentials.
//  Enumeration (quota / rootFolderID / listAllFiles) arrives in M3 and throws
//  a clear "not implemented yet" until then.
//

import Foundation
import NeodiskKit

public struct GoogleDriveProvider: CloudProvider {
    public let providerID = "google"
    public let displayName = "Google Drive"

    private let configuration: GoogleOAuthConfiguration
    private let transport: any CloudTransport
    private let tokenStore: any TokenStoring

    private static let identityEndpoint =
        URL(string: "https://www.googleapis.com/drive/v3/about?fields=user")!
    private static let quotaEndpoint =
        URL(string: "https://www.googleapis.com/drive/v3/about?fields=storageQuota(limit,usage,usageInDrive)")!
    private static let rootEndpoint =
        URL(string: "https://www.googleapis.com/drive/v3/files/root?fields=id")!
    private static let filesEndpoint =
        URL(string: "https://www.googleapis.com/drive/v3/files")!

    /// Requested per file; kept in sync with the DriveFileDTO fields below.
    private static let fileFields =
        "id,name,size,quotaBytesUsed,parents,mimeType,modifiedTime,md5Checksum,ownedByMe,shortcutDetails"
    private static let folderMimeType = "application/vnd.google-apps.folder"
    private static let shortcutMimeType = "application/vnd.google-apps.shortcut"

    public init(
        configuration: GoogleOAuthConfiguration,
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
            throw GoogleDriveError.notConfigured
        }

        let authorizer = OAuthAuthorizer(configuration: configuration.oauthClient, transport: transport)
        let tokens = try await authorizer.authorize(openURL: openURL)

        let identity = try await fetchIdentity(accessToken: tokens.accessToken)
        guard let refreshToken = tokens.refreshToken else {
            // prompt=consent should always return one; guard anyway.
            throw GoogleDriveError.missingRefreshToken
        }

        let credentials = StoredCredentials(
            refreshToken: refreshToken,
            accessToken: tokens.accessToken,
            accessTokenExpiry: tokens.expiryDate,
            email: identity.emailAddress
        )
        try tokenStore.save(credentials, forProviderID: providerID, accountID: identity.permissionId)

        return CloudAccount(
            providerID: providerID,
            accountID: identity.permissionId,
            email: identity.emailAddress
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
        if let credentials = try? tokenStore.load(
            forProviderID: providerID, accountID: account.accountID
        ) {
            let authorizer = OAuthAuthorizer(configuration: configuration.oauthClient, transport: transport)
            await authorizer.revoke(token: credentials.refreshToken)
        }
        try tokenStore.delete(forProviderID: providerID, accountID: account.accountID)
    }

    // MARK: - Enumeration (M3)

    public func quota(for account: CloudAccount) async throws -> CloudQuota {
        let data = try await makeClient(for: account).get(Self.quotaEndpoint)
        let quota = try JSONDecoder().decode(StorageQuotaResponseDTO.self, from: data).storageQuota
        // usageInDrive is Drive-only, so the treemap reconciles against it;
        // `usage` folds in Gmail/Photos and drives the free-space figure.
        // A missing limit means unlimited.
        return CloudQuota(
            totalBytes: quota?.limit?.value,
            usedBytes: quota?.usageInDrive?.value ?? 0,
            accountUsedBytes: quota?.usage?.value
        )
    }

    public func rootFolderID(for account: CloudAccount) async throws -> String {
        let data = try await makeClient(for: account).get(Self.rootEndpoint)
        return try JSONDecoder().decode(DriveRootDTO.self, from: data).id
    }

    public func listAllFiles(
        for account: CloudAccount
    ) -> AsyncThrowingStream<[CloudFileEntry], Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let client = self.makeClient(for: account)
                    var pageToken: String?
                    repeat {
                        try Task.checkCancellation()
                        let url = Self.filesListURL(pageToken: pageToken)
                        let data = try await client.get(url)
                        let page = try JSONDecoder().decode(DriveFileListDTO.self, from: data)
                        continuation.yield((page.files ?? []).map(Self.entry(from:)))
                        pageToken = page.nextPageToken
                    } while pageToken != nil
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

    private func makeClient(for account: CloudAccount) -> GoogleAPIClient {
        let broker = TokenBroker(
            providerID: providerID,
            accountID: account.accountID,
            authorizer: authorizer,
            tokenStore: tokenStore
        )
        return GoogleAPIClient(transport: transport, broker: broker)
    }

    private static func filesListURL(pageToken: String?) -> URL {
        var components = URLComponents(url: filesEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "q", value: "trashed=false"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "fields", value: "nextPageToken,files(\(fileFields))")
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Mapping

    static func entry(from dto: DriveFileDTO) -> CloudFileEntry {
        let isFolder = dto.mimeType == folderMimeType
        let isShortcut = dto.mimeType == shortcutMimeType
        // Shortcuts are 0-byte leaves; never follow them to their target.
        let logicalBytes = isShortcut ? 0 : dto.size?.value
        let quotaBytes = isShortcut ? 0 : (dto.quotaBytesUsed?.value ?? 0)
        return CloudFileEntry(
            id: dto.id,
            name: dto.name ?? dto.id,
            // Drive files have at most one parent since 2020; shared items may
            // have none, which the tree builder buckets as orphaned.
            parentID: dto.parents?.first,
            isFolder: isFolder,
            logicalBytes: logicalBytes,
            quotaBytes: quotaBytes,
            modifiedAt: dto.modifiedTime.flatMap(parseRFC3339),
            contentHash: dto.md5Checksum,
            kindHint: dto.mimeType,
            isOwnedByMe: dto.ownedByMe ?? true
        )
    }

    /// Drive stamps RFC3339 with fractional seconds ("…T…​.123Z"), but be
    /// tolerant of the whole-second form too.
    static func parseRFC3339(_ string: String) -> Date? {
        rfc3339Fractional.date(from: string) ?? rfc3339Whole.date(from: string)
    }

    // Read-only after construction; ISO8601DateFormatter parsing is
    // thread-safe as long as the format options aren't mutated.
    private nonisolated(unsafe) static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let rfc3339Whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Identity

    private func fetchIdentity(accessToken: String) async throws -> AboutUserDTO {
        var request = URLRequest(url: Self.identityEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.execute(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleDriveError.identityFetchFailed(status: response.statusCode)
        }
        return try JSONDecoder().decode(AboutResponseDTO.self, from: data).user
    }
}

public enum GoogleDriveError: Error, Equatable, Sendable {
    case notConfigured
    case missingRefreshToken
    case identityFetchFailed(status: Int)
    /// A non-retryable API error, carrying Google's own error message.
    case requestFailed(status: Int, message: String?)
}

extension GoogleDriveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Drive isn't set up in this build of Neodisk yet."
        case .missingRefreshToken:
            return "Google did not return a refresh token. Try connecting again."
        case .identityFetchFailed(let status):
            return "Could not read your Google account details (HTTP \(status))."
        case .requestFailed(let status, let message):
            if let message {
                return "Google Drive request failed (HTTP \(status)): \(message)"
            }
            return "Google Drive request failed (HTTP \(status))."
        }
    }
}

private struct AboutResponseDTO: Decodable {
    let user: AboutUserDTO
}

private struct AboutUserDTO: Decodable {
    let emailAddress: String
    let permissionId: String
}

// MARK: - Enumeration DTOs

/// Google reports byte counts (size, quotaBytesUsed, storageQuota.*) as JSON
/// strings to survive 53-bit float limits; decode either a string or a raw
/// number, and treat unparseable values as absent rather than failing the
/// whole listing.
struct FlexibleInt64: Decodable, Equatable {
    let value: Int64?

    init(value: Int64?) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Int64(string)
        } else {
            value = nil
        }
    }
}

private struct StorageQuotaResponseDTO: Decodable {
    let storageQuota: StorageQuotaDTO?
}

private struct StorageQuotaDTO: Decodable {
    let limit: FlexibleInt64?
    /// Account-wide usage across all Google services (Drive, Gmail, Photos).
    let usage: FlexibleInt64?
    let usageInDrive: FlexibleInt64?
}

private struct DriveRootDTO: Decodable {
    let id: String
}

struct DriveFileListDTO: Decodable {
    let nextPageToken: String?
    let files: [DriveFileDTO]?
}

struct DriveFileDTO: Decodable {
    let id: String
    let name: String?
    let size: FlexibleInt64?
    let quotaBytesUsed: FlexibleInt64?
    let parents: [String]?
    let mimeType: String?
    let modifiedTime: String?
    let md5Checksum: String?
    let ownedByMe: Bool?
    let shortcutDetails: ShortcutDetailsDTO?
}

struct ShortcutDetailsDTO: Decodable {
    let targetId: String?
    let targetMimeType: String?
}
