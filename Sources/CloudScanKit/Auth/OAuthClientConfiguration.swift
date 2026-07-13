//
//  OAuthClientConfiguration.swift
//  Neodisk
//
//  Provider-neutral OAuth 2.0 client description for the loopback PKCE flow.
//  Each provider's configuration type (Google, Dropbox, OneDrive, …) reduces
//  itself to one of these for OAuthAuthorizer; provider quirks live in
//  `extraAuthParameters` (e.g. Google's access_type=offline&prompt=consent,
//  Dropbox's token_access_type=offline) and the optional client secret
//  (Google desktop clients require theirs at the token endpoint).
//

import Foundation

public struct OAuthClientConfiguration: Sendable, Equatable {
    public var clientID: String
    /// Sent at the token endpoint when present. Non-confidential for
    /// installed apps under PKCE, but still kept out of the public repo.
    public var clientSecret: String?
    public var authEndpoint: URL
    public var tokenEndpoint: URL
    /// nil for providers with no revocation endpoint (sign-out then only
    /// deletes the stored credentials).
    public var revokeEndpoint: URL?
    public var scope: String
    /// Provider-specific query items appended to the authorization URL, in
    /// order.
    public var extraAuthParameters: [(name: String, value: String)]

    public init(
        clientID: String,
        clientSecret: String? = nil,
        authEndpoint: URL,
        tokenEndpoint: URL,
        revokeEndpoint: URL? = nil,
        scope: String,
        extraAuthParameters: [(name: String, value: String)] = []
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authEndpoint = authEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revokeEndpoint = revokeEndpoint
        self.scope = scope
        self.extraAuthParameters = extraAuthParameters
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clientID == rhs.clientID
            && lhs.clientSecret == rhs.clientSecret
            && lhs.authEndpoint == rhs.authEndpoint
            && lhs.tokenEndpoint == rhs.tokenEndpoint
            && lhs.revokeEndpoint == rhs.revokeEndpoint
            && lhs.scope == rhs.scope
            && lhs.extraAuthParameters.elementsEqual(rhs.extraAuthParameters, by: ==)
    }
}
