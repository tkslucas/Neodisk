import Testing
import Foundation
import NeodiskKit
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

@Suite(.serialized) struct GoogleDriveProviderTests {
    @Test func testAuthorizeExchangesCodeFetchesIdentityAndStores() async throws {
        // Token exchange, then the Drive `about` identity lookup.
        let transport = FakeTransport(responses: [
            .json(200, [
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_in": 3600,
                "token_type": "Bearer"
            ]),
            .json(200, ["user": ["emailAddress": "me@example.com", "permissionId": "perm-123"]])
        ])
        let store = InMemoryTokenStore()
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )

        // The stub browser: read the loopback redirect + state out of the auth
        // URL and immediately hit the loopback server with a matching code.
        let account = try await provider.authorize { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value,
                  var callback = URLComponents(string: redirect) else { return }
            callback.queryItems = [
                URLQueryItem(name: "code", value: "auth-code"),
                URLQueryItem(name: "state", value: state)
            ]
            let target = callback.url!
            Task { _ = try? await URLSession.shared.data(from: target) }
        }

        #expect(account.accountID == "perm-123")
        #expect(account.email == "me@example.com")
        #expect(account.providerID == "google")

        let stored = try store.load(forProviderID: "google", accountID: "perm-123")
        #expect(stored?.refreshToken == "refresh-1")
        #expect(stored?.email == "me@example.com")
    }

    @Test func testAuthorizeThrowsWhenNotConfigured() async throws {
        let provider = GoogleDriveProvider(
            configuration: GoogleOAuthConfiguration(clientID: ""),
            transport: FakeTransport(responses: []),
            tokenStore: InMemoryTokenStore()
        )
        await #expect(throws: GoogleDriveError.notConfigured) {
            _ = try await provider.authorize { _ in }
        }
    }

    @Test func testRestoreAndSignOutRoundTrip() async throws {
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(refreshToken: "r", accessToken: "a", email: "me@example.com"),
            forProviderID: "google", accountID: "perm-1"
        )
        // One 200 for the best-effort revoke during sign-out.
        let transport = FakeTransport(responses: [.empty(200)])
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )

        let accounts = try provider.restoreAccounts()
        #expect(accounts.map(\.accountID) == ["perm-1"])
        #expect(accounts.first?.email == "me@example.com")

        try await provider.signOut(accounts[0])
        #expect(try provider.restoreAccounts().isEmpty)
        #expect(transport.bodies.first?.contains("token=r") == true)
    }

    @Test func testEnumerationThrowsNotImplemented() async throws {
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(),
            transport: FakeTransport(responses: []),
            tokenStore: InMemoryTokenStore()
        )
        let account = CloudAccount(providerID: "google", accountID: "a", email: "e")

        await #expect(throws: CloudScanError.self) { _ = try await provider.quota(for: account) }
        await #expect(throws: CloudScanError.self) { _ = try await provider.rootFolderID(for: account) }
        await #expect(throws: CloudScanError.self) {
            for try await _ in provider.listAllFiles(for: account) {}
        }
    }
}
