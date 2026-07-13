import Testing
import Foundation
@testable import CloudScanKit

private func testConfiguration() -> GoogleOAuthConfiguration {
    GoogleOAuthConfiguration(
        clientID: "test-client",
        clientSecret: "test-secret",
        authEndpoint: URL(string: "https://accounts.example.com/auth")!,
        tokenEndpoint: URL(string: "https://oauth.example.com/token")!,
        revokeEndpoint: URL(string: "https://oauth.example.com/revoke")!
    )
}

@Suite struct OAuthAuthorizerTests {
    @Test func testExchangeCodePostsFormAndDecodesTokens() async throws {
        let transport = FakeTransport(responses: [
            .json(200, [
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_in": 3600,
                "token_type": "Bearer",
                "scope": "drive.metadata.readonly"
            ])
        ])
        let authorizer = OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport)

        let tokens = try await authorizer.exchangeCode(
            "the-code", verifier: "the-verifier", redirectURI: "http://127.0.0.1:5000"
        )

        #expect(tokens.accessToken == "access-1")
        #expect(tokens.refreshToken == "refresh-1")
        #expect(tokens.expiryDate != nil)

        let body = transport.bodies[0]
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=the-verifier"))
        #expect(body.contains("client_secret=test-secret"))
        #expect(body.contains("code=the-code"))
    }

    @Test func testRefreshKeepsRefreshTokenWhenResponseOmitsIt() async throws {
        let transport = FakeTransport(responses: [
            .json(200, ["access_token": "access-2", "expires_in": 3600, "token_type": "Bearer"])
        ])
        let authorizer = OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport)

        let tokens = try await authorizer.refresh(refreshToken: "keep-me")

        #expect(tokens.accessToken == "access-2")
        #expect(tokens.refreshToken == "keep-me")

        let body = transport.bodies[0]
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=keep-me"))
        #expect(body.contains("client_secret=test-secret"))
    }

    @Test func testHTTPErrorSurfacesGoogleErrorFields() async throws {
        let transport = FakeTransport(responses: [
            .json(400, ["error": "invalid_grant", "error_description": "Bad Request"])
        ])
        let authorizer = OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport)

        await #expect(throws: OAuthError.httpError(status: 400, error: "invalid_grant", description: "Bad Request")) {
            _ = try await authorizer.exchangeCode("c", verifier: "v", redirectURI: "http://127.0.0.1:1")
        }
    }

    @Test func testRevokePostsToken() async throws {
        let transport = FakeTransport(responses: [.empty(200)])
        let authorizer = OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: transport)

        await authorizer.revoke(token: "revoke-me")

        #expect(transport.requests[0].url == testConfiguration().revokeEndpoint)
        #expect(transport.bodies[0].contains("token=revoke-me"))
    }

    @Test func testAuthorizationURLCarriesPKCEAndState() {
        let authorizer = OAuthAuthorizer(configuration: testConfiguration().oauthClient, transport: FakeTransport(responses: []))
        let url = authorizer.buildAuthorizationURL(
            redirectURI: "http://127.0.0.1:5000", state: "st", codeChallenge: "chal"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("client_id") == "test-client")
        #expect(value("redirect_uri") == "http://127.0.0.1:5000")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge") == "chal")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "st")
        #expect(value("access_type") == "offline")
        #expect(value("prompt") == "consent")
    }
}
