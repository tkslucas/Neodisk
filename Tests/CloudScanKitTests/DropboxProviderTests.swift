import Testing
import Foundation
import NeodiskKit
@testable import CloudScanKit

private func testConfiguration() -> DropboxOAuthConfiguration {
    DropboxOAuthConfiguration(
        clientID: "test-app-key",
        authEndpoint: URL(string: "https://dropbox.example.com/authorize")!,
        tokenEndpoint: URL(string: "https://api.example.com/oauth2/token")!
    )
}

@Suite(.serialized) struct DropboxProviderTests {
    @Test func testAuthorizeExchangesCodeFetchesIdentityAndStores() async throws {
        // Token exchange, then the get_current_account identity lookup.
        let transport = FakeTransport(responses: [
            .json(200, [
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_in": 14400,
                "token_type": "bearer"
            ]),
            .json(200, [
                "account_id": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
                "email": "me@example.com",
                "name": ["display_name": "Me"]
            ])
        ])
        let store = InMemoryTokenStore()
        let provider = DropboxProvider(
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

        #expect(account.accountID == "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
        #expect(account.email == "me@example.com")
        #expect(account.providerID == "dropbox")

        let stored = try store.load(
            forProviderID: "dropbox", accountID: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc"
        )
        #expect(stored?.refreshToken == "refresh-1")
        #expect(stored?.email == "me@example.com")

        // The exchange POST is a pure-PKCE public client: no client_secret, and
        // the authorization request forced a refresh token via
        // token_access_type=offline.
        #expect(transport.bodies[0].contains("code_verifier="))
        #expect(!transport.bodies[0].contains("client_secret"))

        // The identity POST carries the bearer and an empty body with no
        // Content-Type (the no-argument RPC form).
        let identityRequest = transport.requests[1]
        #expect(identityRequest.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(identityRequest.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect((identityRequest.httpBody?.isEmpty ?? true))
    }

    @Test func testAuthorizationURLCarriesOfflineAndOmitsSecret() async throws {
        let authorizer = OAuthAuthorizer(
            configuration: testConfiguration().oauthClient,
            transport: FakeTransport(responses: [])
        )
        let url = authorizer.buildAuthorizationURL(
            redirectURI: "http://127.0.0.1:1234/callback", state: "st", codeChallenge: "cc"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "token_access_type" }?.value == "offline")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.contains { $0.name == "client_secret" } == false)
    }

    @Test func testAuthorizeThrowsWhenNotConfigured() async throws {
        let provider = DropboxProvider(
            configuration: DropboxOAuthConfiguration(clientID: ""),
            transport: FakeTransport(responses: []),
            tokenStore: InMemoryTokenStore()
        )
        await #expect(throws: DropboxError.notConfigured) {
            _ = try await provider.authorize { _ in }
        }
    }

    @Test func testRestoreAndSignOutRevokesWithBearerThenDeletes() async throws {
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(
                refreshToken: "r", accessToken: "access-live",
                accessTokenExpiry: Date().addingTimeInterval(3600), email: "me@example.com"
            ),
            forProviderID: "dropbox", accountID: "dbid:1"
        )
        // One 200 for the best-effort revoke during sign-out.
        let transport = FakeTransport(responses: [.empty(200)])
        let provider = DropboxProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )

        let accounts = try provider.restoreAccounts()
        #expect(accounts.map(\.accountID) == ["dbid:1"])
        #expect(accounts.first?.email == "me@example.com")

        try await provider.signOut(accounts[0])
        #expect(try provider.restoreAccounts().isEmpty)
        // Revoke is a Bearer-authenticated API call, not an OAuth form post.
        let revoke = transport.requests[0]
        #expect(revoke.url == URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
        #expect(revoke.value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
    }

    // MARK: - Enumeration

    /// A store holding a still-valid access token, so the broker serves it
    /// without a refresh round-trip.
    private func connectedStore(accountID: String = "dbid:1") -> InMemoryTokenStore {
        let store = InMemoryTokenStore()
        try! store.save(
            StoredCredentials(
                refreshToken: "refresh-1",
                accessToken: "access-live",
                accessTokenExpiry: Date().addingTimeInterval(3600),
                email: "me@example.com"
            ),
            forProviderID: "dropbox", accountID: accountID
        )
        return store
    }

    private func connectedAccount(_ accountID: String = "dbid:1") -> CloudAccount {
        CloudAccount(providerID: "dropbox", accountID: accountID, email: "me@example.com")
    }

    @Test func testQuotaMapsUsedAndAllocation() async throws {
        let transport = FakeTransport(responses: [
            .json(200, [
                "used": 314159265,
                "allocation": [".tag": "individual", "allocated": 10737418240]
            ])
        ])
        let provider = DropboxProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        let quota = try await provider.quota(for: connectedAccount())
        #expect(quota.totalBytes == 10737418240)
        #expect(quota.usedBytes == 314159265)
        // Dropbox has no per-service split, so both usages are the same figure.
        #expect(quota.accountUsedBytes == 314159265)
        // The no-arg RPC posts an empty body with no Content-Type.
        #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
    }

    @Test func testQuotaUnlimitedWhenAllocationAbsent() async throws {
        let transport = FakeTransport(responses: [
            .json(200, ["used": 100, "allocation": [".tag": "individual"]])
        ])
        let provider = DropboxProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        let quota = try await provider.quota(for: connectedAccount())
        #expect(quota.totalBytes == nil)
        #expect(quota.usedBytes == 100)
    }

    @Test func testRootFolderIDIsConstantWithoutNetwork() async throws {
        let transport = FakeTransport(responses: [])
        let provider = DropboxProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        #expect(try await provider.rootFolderID(for: connectedAccount()) == "dropbox-root")
        // No request was made.
        #expect(transport.requests.isEmpty)
    }

    @Test func testListAllFilesPagesViaCursorAndHasMore() async throws {
        let transport = FakeTransport(responses: [
            .json(200, [
                "entries": [
                    [".tag": "file", "id": "id:a", "name": "a.txt",
                     "path_display": "/a.txt", "path_lower": "/a.txt", "size": 10]
                ],
                "cursor": "CURSOR2",
                "has_more": true
            ]),
            .json(200, [
                "entries": [
                    [".tag": "file", "id": "id:b", "name": "b.txt",
                     "path_display": "/b.txt", "path_lower": "/b.txt", "size": 20]
                ],
                "cursor": "CURSOR3",
                "has_more": false
            ])
        ])
        let provider = DropboxProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )

        var ids: [String] = []
        for try await page in provider.listAllFiles(for: connectedAccount()) {
            ids.append(contentsOf: page.map(\.id))
        }
        #expect(ids == ["id:a", "id:b"])

        // First request hits list_folder with the initial recursive body; the
        // second hits list_folder/continue carrying the previous cursor.
        #expect(transport.requests[0].url ==
                URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        #expect(transport.bodies[0].contains("\"recursive\":true"))
        #expect(transport.requests[1].url ==
                URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
        #expect(transport.bodies[1].contains("CURSOR2"))
    }

    @Test func testEntryMappingDeletedFolderFileAndSpacedPaths() throws {
        func decode(_ json: String) throws -> DropboxEntryDTO {
            try JSONDecoder().decode(DropboxEntryDTO.self, from: Data(json.utf8))
        }

        // Deleted tombstone → dropped.
        let deleted = DropboxProvider.entry(from: try decode(
            #"{".tag":"deleted","name":"gone.txt","path_display":"/gone.txt"}"#
        ))
        #expect(deleted == nil)

        // Folder: no size, path split on "/".
        let folder = try #require(DropboxProvider.entry(from: try decode(
            #"{".tag":"folder","id":"id:d","name":"My Docs","path_display":"/My Docs","path_lower":"/my docs"}"#
        )))
        #expect(folder.isFolder)
        #expect(folder.logicalBytes == nil)
        #expect(folder.quotaBytes == nil)
        #expect(folder.pathComponents == ["My Docs"])

        // File with a space in a nested path: both size fields set, path split
        // preserves the spaces and drops the leading root slash.
        let file = try #require(DropboxProvider.entry(from: try decode(
            #"{".tag":"file","id":"id:f","name":"report final.pdf","path_display":"/My Docs/report final.pdf","path_lower":"/my docs/report final.pdf","size":4096,"server_modified":"2026-03-04T05:06:07Z","content_hash":"abc123"}"#
        )))
        #expect(!file.isFolder)
        #expect(file.logicalBytes == 4096)
        #expect(file.quotaBytes == 4096)
        #expect(file.pathComponents == ["My Docs", "report final.pdf"])
        #expect(file.contentHash == "abc123")
        #expect(file.modifiedAt != nil)
        #expect(file.isOwnedByMe)
    }

    @Test func testISO8601ParsingToleratesWholeAndFractional() {
        #expect(DropboxProvider.parseISO8601("2026-03-04T05:06:07Z") != nil)
        #expect(DropboxProvider.parseISO8601("2026-03-04T05:06:07.123Z") != nil)
        #expect(DropboxProvider.parseISO8601("not-a-date") == nil)
    }
}
