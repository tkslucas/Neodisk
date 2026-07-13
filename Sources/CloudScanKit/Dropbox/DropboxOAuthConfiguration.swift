//
//  DropboxOAuthConfiguration.swift
//  Neodisk
//
//  Endpoints and client identity for Dropbox's OAuth 2.0 loopback flow. Unlike
//  Google's desktop client, Dropbox is a pure PKCE public client with no client
//  secret. The "app key" is read from the environment so a real Dropbox app can
//  be swapped in without touching source; until one is registered the
//  placeholder leaves the app key empty, which the provider reports as "not
//  configured" (and the connect menu stays hidden).
//

import Foundation

public struct DropboxOAuthConfiguration: Sendable, Equatable {
    /// Dropbox calls this the app's "app key".
    public var clientID: String
    public var authEndpoint: URL
    public var tokenEndpoint: URL
    public var scope: String

    public static let defaultScope = "files.metadata.read account_info.read"

    public static let defaultAuthEndpoint =
        URL(string: "https://www.dropbox.com/oauth2/authorize")!
    public static let defaultTokenEndpoint =
        URL(string: "https://api.dropboxapi.com/oauth2/token")!

    public init(
        clientID: String,
        authEndpoint: URL = DropboxOAuthConfiguration.defaultAuthEndpoint,
        tokenEndpoint: URL = DropboxOAuthConfiguration.defaultTokenEndpoint,
        scope: String = DropboxOAuthConfiguration.defaultScope
    ) {
        self.clientID = clientID
        self.authEndpoint = authEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scope = scope
    }

    /// True once an app key is present. When false the provider reports
    /// authorization is unavailable and the UI hides the connect action.
    public var isConfigured: Bool { !clientID.isEmpty }

    /// The provider-neutral client OAuthAuthorizer consumes. Dropbox quirks:
    /// no client secret (public PKCE client), and token_access_type=offline
    /// forces a refresh token on every connect so a reconnect is never left
    /// with only a short-lived access token. revokeEndpoint is nil because
    /// Dropbox revocation is a Bearer-authenticated API call (see
    /// DropboxProvider.signOut), not an OAuth revoke form.
    public var oauthClient: OAuthClientConfiguration {
        OAuthClientConfiguration(
            clientID: clientID,
            clientSecret: nil,
            authEndpoint: authEndpoint,
            tokenEndpoint: tokenEndpoint,
            revokeEndpoint: nil,
            scope: scope,
            extraAuthParameters: [
                (name: "token_access_type", value: "offline")
            ]
        )
    }

    // MARK: - Licensing-deferred swap point
    //
    // Registering the Dropbox app (and its OAuth consent screen) is deferred;
    // until then this stays empty and the feature reports itself as
    // unconfigured. Supply a real app key via the environment variable below
    // to light the flow up.
    static let placeholderClientID = ""

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DropboxOAuthConfiguration {
        let clientID = environment["NEODISK_DROPBOX_APP_KEY"] ?? placeholderClientID
        return DropboxOAuthConfiguration(clientID: clientID)
    }
}
