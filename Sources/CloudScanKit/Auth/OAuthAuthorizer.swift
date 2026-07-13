//
//  OAuthAuthorizer.swift
//  Neodisk
//
//  The OAuth 2.0 authorization-code-with-PKCE dance for a loopback public
//  client: mint PKCE + state, stand up the loopback listener, open the
//  consent URL in the browser, catch the redirect, and exchange the code for
//  tokens. Also refreshes and revokes. All HTTP goes through CloudTransport,
//  so tests drive it with scripted responses.
//

import Foundation

/// Tokens returned by the token endpoint.
struct OAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var scope: String?
    var tokenType: String?
    /// When the access token expires, derived from `expires_in` at receipt.
    var expiryDate: Date?
}

enum OAuthError: Error, Equatable, Sendable {
    case invalidResponse
    /// Non-2xx from the token/revoke endpoint, with Google's `error` /
    /// `error_description` when present.
    case httpError(status: Int, error: String?, description: String?)
    case missingAccessToken
}

struct OAuthAuthorizer: Sendable {
    let configuration: OAuthClientConfiguration
    let transport: any CloudTransport
    /// Injected for tests; production stamps the receipt time onto expiry.
    var now: @Sendable () -> Date = { Date() }

    // MARK: - Full authorization

    /// Runs the browser consent flow and returns the granted tokens. Starts
    /// the loopback listener, awaits the redirect, then exchanges the code.
    func authorize(openURL: @Sendable @escaping (URL) -> Void) async throws -> OAuthTokens {
        let pkce = PKCE.generate()
        let state = Self.randomState()
        let server = try OAuthLoopbackServer.start()
        let redirectURI = server.redirectURI

        let authURL = buildAuthorizationURL(
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.challenge
        )

        // Set the callback wait up before opening the browser, so a fast
        // redirect can't race ahead of the listener's connection handler.
        async let code = server.waitForCallback(expectedState: state)
        openURL(authURL)
        let authorizationCode = try await code

        return try await exchangeCode(
            authorizationCode,
            verifier: pkce.verifier,
            redirectURI: redirectURI
        )
    }

    func buildAuthorizationURL(redirectURI: String, state: String, codeChallenge: String) -> URL {
        var components = URLComponents(
            url: configuration.authEndpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ] + configuration.extraAuthParameters.map { URLQueryItem(name: $0.name, value: $0.value) }
        return components.url!
    }

    // MARK: - Token endpoint

    func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        var fields = [
            "code": code,
            "client_id": configuration.clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if let secret = configuration.clientSecret {
            fields["client_secret"] = secret
        }
        return try await postForm(to: configuration.tokenEndpoint, fields: fields)
    }

    func refresh(refreshToken: String) async throws -> OAuthTokens {
        var fields = [
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
            "grant_type": "refresh_token"
        ]
        if let secret = configuration.clientSecret {
            fields["client_secret"] = secret
        }
        var tokens = try await postForm(to: configuration.tokenEndpoint, fields: fields)
        // A refresh response omits the refresh token; keep the caller's.
        if tokens.refreshToken == nil {
            tokens.refreshToken = refreshToken
        }
        return tokens
    }

    /// Best-effort revocation — failures are swallowed; the credentials are
    /// deleted regardless by the caller. No-op for providers without a
    /// revocation endpoint.
    func revoke(token: String) async {
        guard let revokeEndpoint = configuration.revokeEndpoint else { return }
        var request = URLRequest(url: revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody(["token": token])
        _ = try? await transport.execute(request)
    }

    // MARK: - Helpers

    private func postForm(to endpoint: URL, fields: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody(fields)

        let (data, response) = try await transport.execute(request)
        guard (200..<300).contains(response.statusCode) else {
            let errorDecoder = JSONDecoder()
            errorDecoder.keyDecodingStrategy = .convertFromSnakeCase
            let error = try? errorDecoder.decode(ErrorResponseDTO.self, from: data)
            throw OAuthError.httpError(
                status: response.statusCode,
                error: error?.error,
                description: error?.errorDescription
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let dto = try? decoder.decode(TokenResponseDTO.self, from: data),
              let accessToken = dto.accessToken else {
            throw OAuthError.missingAccessToken
        }
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: dto.refreshToken,
            scope: dto.scope,
            tokenType: dto.tokenType,
            expiryDate: dto.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
        )
    }

    /// application/x-www-form-urlencoded body with form (`+` for space)
    /// percent-encoding.
    static func formBody(_ fields: [String: String]) -> Data {
        let encoded = fields.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncodedString()
    }
}

private struct TokenResponseDTO: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?
    let tokenType: String?
}

private struct ErrorResponseDTO: Decodable {
    let error: String?
    let errorDescription: String?
}
