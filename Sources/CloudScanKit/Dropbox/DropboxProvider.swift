//
//  DropboxProvider.swift
//  Neodisk
//
//  The Dropbox CloudProvider. authorize() runs the loopback PKCE flow, reads
//  the account identity from users/get_current_account, and persists
//  credentials. Enumeration lists the whole drive via files/list_folder with
//  path-linkage (Dropbox reports full paths, not parent IDs), which
//  CloudTreeBuilder anchors to the synthetic "dropbox-root" root.
//

import Foundation

public struct DropboxProvider: CloudProvider {
    public let providerID = "dropbox"
    public let displayName = "Dropbox"

    /// Dropbox has no numeric root ID: entries are path-linked and the tree
    /// builder anchors them to whatever root the provider reports.
    public static let rootID = "dropbox-root"

    private let configuration: DropboxOAuthConfiguration
    private let transport: any CloudTransport
    private let tokenStore: any TokenStoring

    private static let identityEndpoint =
        URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!
    private static let spaceUsageEndpoint =
        URL(string: "https://api.dropboxapi.com/2/users/get_space_usage")!
    private static let listFolderEndpoint =
        URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
    private static let listFolderContinueEndpoint =
        URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
    private static let revokeEndpoint =
        URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!

    /// Whole-drive recursive listing, 2000 entries per page.
    private static let initialListBody = Data(
        #"{"path":"","recursive":true,"include_non_downloadable_files":true,"limit":2000}"#.utf8
    )

    public init(
        configuration: DropboxOAuthConfiguration,
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
            throw DropboxError.notConfigured
        }

        let authorizer = OAuthAuthorizer(configuration: configuration.oauthClient, transport: transport)
        let tokens = try await authorizer.authorize(openURL: openURL)

        let identity = try await fetchIdentity(accessToken: tokens.accessToken)
        guard let refreshToken = tokens.refreshToken else {
            // token_access_type=offline should always return one; guard anyway.
            throw DropboxError.missingRefreshToken
        }

        let credentials = StoredCredentials(
            refreshToken: refreshToken,
            accessToken: tokens.accessToken,
            accessTokenExpiry: tokens.expiryDate,
            email: identity.email
        )
        try tokenStore.save(credentials, forProviderID: providerID, accountID: identity.accountID)

        return CloudAccount(
            providerID: providerID,
            accountID: identity.accountID,
            email: identity.email
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
        // Best-effort revoke: a Bearer-authenticated API call, unlike the OAuth
        // revoke form Google uses. A valid token is nicer but a stale one is
        // fine — the credentials are deleted regardless below.
        if let credentials = try? tokenStore.load(
            forProviderID: providerID, accountID: account.accountID
        ) {
            let broker = makeBroker(for: account)
            let token = (try? await broker.validToken()) ?? credentials.accessToken
            if let token {
                var request = URLRequest(url: Self.revokeEndpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                _ = try? await transport.execute(request)
            }
        }
        try tokenStore.delete(forProviderID: providerID, accountID: account.accountID)
    }

    // MARK: - Enumeration

    public func quota(for account: CloudAccount) async throws -> CloudQuota {
        let data = try await makeClient(for: account).post(Self.spaceUsageEndpoint)
        let usage = try JSONDecoder().decode(SpaceUsageDTO.self, from: data)
        // Dropbox quota is all-Dropbox — there is no per-service split — so the
        // treemap reconciles against the same figure the free-space display
        // reckons with. A missing allocation means unlimited.
        return CloudQuota(
            totalBytes: usage.allocation.allocated,
            usedBytes: usage.used,
            accountUsedBytes: usage.used
        )
    }

    public func rootFolderID(for account: CloudAccount) async throws -> String {
        Self.rootID
    }

    public func listAllFiles(
        for account: CloudAccount
    ) -> AsyncThrowingStream<[CloudFileEntry], Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let client = self.makeClient(for: account)
                    var data = try await client.post(
                        Self.listFolderEndpoint, jsonBody: Self.initialListBody
                    )
                    var page = try JSONDecoder().decode(ListFolderDTO.self, from: data)
                    continuation.yield(page.entries.compactMap(Self.entry(from:)))
                    while page.hasMore {
                        try Task.checkCancellation()
                        data = try await client.post(
                            Self.listFolderContinueEndpoint,
                            jsonBody: Self.continueBody(cursor: page.cursor)
                        )
                        page = try JSONDecoder().decode(ListFolderDTO.self, from: data)
                        continuation.yield(page.entries.compactMap(Self.entry(from:)))
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

    private func makeBroker(for account: CloudAccount) -> TokenBroker {
        TokenBroker(
            providerID: providerID,
            accountID: account.accountID,
            authorizer: authorizer,
            tokenStore: tokenStore
        )
    }

    private func makeClient(for account: CloudAccount) -> DropboxAPIClient {
        DropboxAPIClient(transport: transport, broker: makeBroker(for: account))
    }

    static func continueBody(cursor: String) throws -> Data {
        try JSONEncoder().encode(["cursor": cursor])
    }

    // MARK: - Mapping

    /// Maps a listing entry to a CloudFileEntry, or nil for a deleted tombstone
    /// (Dropbox includes those in recursive listings). Folders carry no size;
    /// files size both `logicalBytes` and `quotaBytes` the same, since Dropbox
    /// quota is the on-disk size.
    static func entry(from dto: DropboxEntryDTO) -> CloudFileEntry? {
        guard dto.tag != "deleted" else { return nil }
        let id = dto.id ?? dto.pathLower ?? dto.name
        let isFolder = dto.tag == "folder"
        let size = isFolder ? nil : dto.size
        return CloudFileEntry(
            id: id,
            name: dto.name,
            pathComponents: pathComponents(from: dto.pathDisplay ?? dto.pathLower),
            isFolder: isFolder,
            logicalBytes: size,
            quotaBytes: size,
            modifiedAt: dto.serverModified.flatMap(parseISO8601),
            contentHash: dto.contentHash,
            kindHint: nil,
            isOwnedByMe: true
        )
    }

    /// Splits a Dropbox display path ("/Docs/report final.pdf") into its
    /// components, dropping the leading empty segment from the root slash.
    /// Names with spaces survive; only "/" separates.
    static func pathComponents(from path: String?) -> [String]? {
        guard let path, !path.isEmpty else { return nil }
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.isEmpty ? nil : components
    }

    /// Dropbox stamps whole-second ISO8601 ("…T…Z"); tolerate a fractional
    /// form too in case a future field carries one.
    static func parseISO8601(_ string: String) -> Date? {
        iso8601Whole.date(from: string) ?? iso8601Fractional.date(from: string)
    }

    // Read-only after construction; ISO8601DateFormatter parsing is
    // thread-safe as long as the format options aren't mutated.
    private nonisolated(unsafe) static let iso8601Whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Identity

    /// get_current_account takes no arguments: POST an empty body with NO
    /// Content-Type (application/json + empty body earns a 400 from Dropbox).
    /// Runs before credentials exist, so it hits the transport directly with
    /// the freshly minted token rather than via the broker.
    private func fetchIdentity(accessToken: String) async throws -> DropboxIdentity {
        var request = URLRequest(url: Self.identityEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.execute(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DropboxError.identityFetchFailed(status: response.statusCode)
        }
        let dto = try JSONDecoder().decode(AccountDTO.self, from: data)
        return DropboxIdentity(accountID: dto.accountId, email: dto.email)
    }
}

public enum DropboxError: Error, Equatable, Sendable {
    case notConfigured
    case missingRefreshToken
    case identityFetchFailed(status: Int)
    /// A non-retryable API error, carrying Dropbox's own error_summary.
    case requestFailed(status: Int, message: String?)
}

extension DropboxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Dropbox isn't set up in this build of Neodisk yet."
        case .missingRefreshToken:
            return "Dropbox did not return a refresh token. Try connecting again."
        case .identityFetchFailed(let status):
            return "Could not read your Dropbox account details (HTTP \(status))."
        case .requestFailed(let status, let message):
            if let message {
                return "Dropbox request failed (HTTP \(status)): \(message)"
            }
            return "Dropbox request failed (HTTP \(status))."
        }
    }
}

// MARK: - DTOs

private struct DropboxIdentity {
    let accountID: String
    let email: String
}

private struct AccountDTO: Decodable {
    let accountId: String
    let email: String
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case email
    }
}

private struct SpaceUsageDTO: Decodable {
    let used: Int64
    let allocation: AllocationDTO

    struct AllocationDTO: Decodable {
        /// Present for both "individual" and "team" allocations; nil (unlimited)
        /// only when Dropbox omits it entirely.
        let allocated: Int64?
    }
}

struct ListFolderDTO: Decodable {
    let entries: [DropboxEntryDTO]
    let cursor: String
    let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case entries, cursor
        case hasMore = "has_more"
    }
}

struct DropboxEntryDTO: Decodable {
    /// ".tag": "file" | "folder" | "deleted".
    let tag: String
    let id: String?
    let name: String
    let pathDisplay: String?
    let pathLower: String?
    let size: Int64?
    let serverModified: String?
    let contentHash: String?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag"
        case id, name, size
        case pathDisplay = "path_display"
        case pathLower = "path_lower"
        case serverModified = "server_modified"
        case contentHash = "content_hash"
    }
}
