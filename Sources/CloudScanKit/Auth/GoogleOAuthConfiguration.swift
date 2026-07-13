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

    /// True once a client ID and secret are present (Google desktop clients
    /// need both at the token endpoint). When false the provider reports
    /// authorization is unavailable and the UI hides the connect action.
    public var isConfigured: Bool {
        !clientID.isEmpty && !(clientSecret ?? "").isEmpty
    }

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

    // MARK: - Shipped client identity
    //
    // Neodisk's registered Google OAuth desktop client ID. It is public by
    // nature (it appears in the auth URL of every sign-in; the flow is
    // protected by PKCE, not by hiding it). The accompanying client secret —
    // required by Google at the token endpoint but likewise documented as
    // non-confidential for installed apps — is deliberately NOT in source:
    // release packaging injects it into Info.plist, and dev builds supply it
    // via NEODISK_GOOGLE_CLIENT_SECRET. Without one the provider reports
    // itself unconfigured and the connect action stays hidden.
    static let shippedClientID =
        "790657586324-s0mh1aaqkkcu2utph11odu043pij5dgl.apps.googleusercontent.com"

    /// Info.plist key the packaging script writes the client secret under.
    public static let clientSecretInfoPlistKey = "NeodiskGoogleClientSecret"

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> GoogleOAuthConfiguration {
        let clientID = environment["NEODISK_GOOGLE_CLIENT_ID"] ?? shippedClientID
        let secret = environment["NEODISK_GOOGLE_CLIENT_SECRET"]
            ?? infoDictionary?[clientSecretInfoPlistKey] as? String
        return GoogleOAuthConfiguration(
            clientID: clientID,
            clientSecret: secret?.isEmpty == false ? secret : nil
        )
    }
}
