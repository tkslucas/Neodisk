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

    private static let aboutEndpoint =
        URL(string: "https://www.googleapis.com/drive/v3/about?fields=user")!
    private static let notImplementedMessage =
        "Google Drive scanning arrives in a later update."

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

        let authorizer = OAuthAuthorizer(configuration: configuration, transport: transport)
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
            let authorizer = OAuthAuthorizer(configuration: configuration, transport: transport)
            await authorizer.revoke(token: credentials.refreshToken)
        }
        try tokenStore.delete(forProviderID: providerID, accountID: account.accountID)
    }

    // MARK: - Enumeration (M3)

    public func quota(for account: CloudAccount) async throws -> CloudQuota {
        throw CloudScanError.unsupportedOperation(Self.notImplementedMessage)
    }

    public func rootFolderID(for account: CloudAccount) async throws -> String {
        throw CloudScanError.unsupportedOperation(Self.notImplementedMessage)
    }

    public func listAllFiles(
        for account: CloudAccount
    ) -> AsyncThrowingStream<[CloudFileEntry], Error> {
        AsyncThrowingStream {
            $0.finish(throwing: CloudScanError.unsupportedOperation(Self.notImplementedMessage))
        }
    }

    // MARK: - Identity

    private func fetchIdentity(accessToken: String) async throws -> AboutUserDTO {
        var request = URLRequest(url: Self.aboutEndpoint)
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
