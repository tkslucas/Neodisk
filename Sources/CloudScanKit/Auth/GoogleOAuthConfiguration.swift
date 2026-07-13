//
//  GoogleOAuthConfiguration.swift
//  Neodisk
//
//  Endpoints and client identity for Google's OAuth 2.0 loopback flow. The
//  client ID/secret are read from the environment so a real Google Cloud
//  project can be swapped in without touching source; until one is registered
//  the placeholders leave the client ID empty, which the provider reports as
//  "not configured" (and the connect menu stays hidden).
//

import Foundation

public struct GoogleOAuthConfiguration: Sendable, Equatable {
    public var clientID: String
    /// Google "Desktop app" clients require the (non-confidential) client
    /// secret at the token endpoint even under PKCE — a documented Google
    /// quirk. It is not a real secret and may ship in the client. Optional so
    /// providers that don't need it can omit it.
    public var clientSecret: String?
    public var authEndpoint: URL
    public var tokenEndpoint: URL
    public var revokeEndpoint: URL
    public var scope: String

    public static let driveMetadataReadonlyScope =
        "https://www.googleapis.com/auth/drive.metadata.readonly"

    public static let defaultAuthEndpoint =
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let defaultTokenEndpoint =
        URL(string: "https://oauth2.googleapis.com/token")!
    public static let defaultRevokeEndpoint =
        URL(string: "https://oauth2.googleapis.com/revoke")!

    public init(
        clientID: String,
        clientSecret: String? = nil,
        authEndpoint: URL = GoogleOAuthConfiguration.defaultAuthEndpoint,
        tokenEndpoint: URL = GoogleOAuthConfiguration.defaultTokenEndpoint,
        revokeEndpoint: URL = GoogleOAuthConfiguration.defaultRevokeEndpoint,
        scope: String = GoogleOAuthConfiguration.driveMetadataReadonlyScope
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authEndpoint = authEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revokeEndpoint = revokeEndpoint
        self.scope = scope
    }

    /// True once a client ID is present. When false the provider reports
    /// authorization is unavailable and the UI hides the connect action.
    public var isConfigured: Bool { !clientID.isEmpty }

    /// The provider-neutral client OAuthAuthorizer consumes. Google quirks:
    /// access_type=offline + prompt=consent force a refresh token on every
    /// connect, so a reconnect is never left with only a short-lived access
    /// token.
    public var oauthClient: OAuthClientConfiguration {
        OAuthClientConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            authEndpoint: authEndpoint,
            tokenEndpoint: tokenEndpoint,
            revokeEndpoint: revokeEndpoint,
            scope: scope,
            extraAuthParameters: [
                (name: "access_type", value: "offline"),
                (name: "prompt", value: "consent")
            ]
        )
    }

    // MARK: - Licensing-deferred swap point
    //
    // Registering the Google Cloud project (and its OAuth consent screen) is
    // deferred; until then these stay empty and the feature reports itself as
    // unconfigured. Swap real values in here, or supply them via the
    // environment variables below, to light the flow up.
    static let placeholderClientID = ""
    static let placeholderClientSecret: String? = nil

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GoogleOAuthConfiguration {
        let clientID = environment["NEODISK_GOOGLE_CLIENT_ID"] ?? placeholderClientID
        let secret = environment["NEODISK_GOOGLE_CLIENT_SECRET"]
        return GoogleOAuthConfiguration(
            clientID: clientID,
            clientSecret: secret?.isEmpty == false ? secret : placeholderClientSecret
        )
    }
}
