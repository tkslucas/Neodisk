//
//  OneDriveOAuthConfiguration.swift
//  Neodisk
//
//  Endpoints and client identity for OneDrive (personal) via Microsoft's
//  identity platform. OneDrive uses a public client (no secret) with a
//  loopback redirect, so the only value read from the environment is the
//  Azure app registration's client ID; until one is registered the
//  placeholder leaves it empty, which the provider reports as "not
//  configured" (and the connect menu stays hidden). Microsoft has no
//  public-client token-revocation endpoint, so `revokeEndpoint` is nil and
//  sign-out only deletes the stored credentials.
//

import Foundation

public struct OneDriveOAuthConfiguration: Sendable, Equatable {
    public var clientID: String
    public var authEndpoint: URL
    public var tokenEndpoint: URL
    public var scope: String

    /// Files.Read for the drive listing, offline_access for the refresh
    /// token (Microsoft rotates it on every refresh), User.Read for the
    /// account identity used to key stored credentials.
    public static let defaultScope = "Files.Read offline_access User.Read"

    public static let defaultAuthEndpoint =
        URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
    public static let defaultTokenEndpoint =
        URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!

    public init(
        clientID: String,
        authEndpoint: URL = OneDriveOAuthConfiguration.defaultAuthEndpoint,
        tokenEndpoint: URL = OneDriveOAuthConfiguration.defaultTokenEndpoint,
        scope: String = OneDriveOAuthConfiguration.defaultScope
    ) {
        self.clientID = clientID
        self.authEndpoint = authEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scope = scope
    }

    /// True once a client ID is present. When false the provider reports
    /// authorization is unavailable and the UI hides the connect action.
    public var isConfigured: Bool { !clientID.isEmpty }

    /// The provider-neutral client OAuthAuthorizer consumes. No client secret
    /// (public client), no revocation endpoint, and no extra authorization
    /// parameters — offline_access in the scope is what yields a refresh
    /// token, so Google's access_type/prompt quirks have no analogue here.
    public var oauthClient: OAuthClientConfiguration {
        OAuthClientConfiguration(
            clientID: clientID,
            clientSecret: nil,
            authEndpoint: authEndpoint,
            tokenEndpoint: tokenEndpoint,
            revokeEndpoint: nil,
            scope: scope
        )
    }

    // MARK: - Registration-deferred swap point
    //
    // Registering the Azure app (public client with a loopback redirect) is
    // deferred; until then this stays empty and the feature reports itself as
    // unconfigured. Swap a real value in here, or supply it via the
    // environment variable below, to light the flow up.
    static let placeholderClientID = ""

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OneDriveOAuthConfiguration {
        let clientID = environment["NEODISK_ONEDRIVE_CLIENT_ID"] ?? placeholderClientID
        return OneDriveOAuthConfiguration(clientID: clientID)
    }
}
