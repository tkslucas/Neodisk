import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    // MARK: - M3 enumeration

    /// A store holding a still-valid access token, so the broker serves it
    /// without a refresh round-trip.
    private func connectedStore(accountID: String = "perm-1") -> InMemoryTokenStore {
        let store = InMemoryTokenStore()
        try! store.save(
            StoredCredentials(
                refreshToken: "refresh-1",
                accessToken: "access-live",
                accessTokenExpiry: Date().addingTimeInterval(3600),
                email: "me@example.com"
            ),
            forProviderID: "google", accountID: accountID
        )
        return store
    }

    private func connectedAccount(_ accountID: String = "perm-1") -> CloudAccount {
        CloudAccount(providerID: "google", accountID: accountID, email: "me@example.com")
    }

    @Test func testQuotaUsesUsageInDriveAndUnlimitedWhenLimitAbsent() async throws {
        let transport = FakeTransport(responses: [
            // No `limit` field → unlimited plan. Distinct usage vs usageInDrive
            // proves each maps to the right field: Drive-only → usedBytes,
            // account-wide → accountUsedBytes.
            .json(200, ["storageQuota": [
                "usage": "9999999",
                "usageInDrive": "4096"
            ]])
        ])
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        let quota = try await provider.quota(for: connectedAccount())
        #expect(quota.totalBytes == nil)
        #expect(quota.usedBytes == 4096)
        #expect(quota.accountUsedBytes == 9999999)
        // The stamped bearer token came from the store.
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
    }

    @Test func testQuotaReadsLimitWhenPresent() async throws {
        let transport = FakeTransport(responses: [
            .json(200, ["storageQuota": [
                "limit": "16106127360", "usage": "9000000000", "usageInDrive": "7300000000"
            ]])
        ])
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        let quota = try await provider.quota(for: connectedAccount())
        #expect(quota.totalBytes == 16106127360)
        #expect(quota.usedBytes == 7300000000)
        #expect(quota.accountUsedBytes == 9000000000)
    }

    @Test func testRootFolderID() async throws {
        let transport = FakeTransport(responses: [.json(200, ["id": "0ABCroot"])])
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        #expect(try await provider.rootFolderID(for: connectedAccount()) == "0ABCroot")
    }

    @Test func testListAllFilesPagesInOrderCarryingPageToken() async throws {
        let transport = FakeTransport(responses: [
            .json(200, [
                "nextPageToken": "PAGE2",
                "files": [["id": "a", "name": "a.txt", "parents": ["root"], "size": "10", "quotaBytesUsed": "10"]]
            ]),
            .json(200, [
                "nextPageToken": "PAGE3",
                "files": [["id": "b", "name": "b.txt", "parents": ["root"], "size": "20", "quotaBytesUsed": "20"]]
            ]),
            .json(200, [
                "files": [["id": "c", "name": "c.txt", "parents": ["root"], "size": "30", "quotaBytesUsed": "30"]]
            ])
        ])
        let provider = GoogleDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )

        var ids: [String] = []
        for try await page in provider.listAllFiles(for: connectedAccount()) {
            ids.append(contentsOf: page.map(\.id))
        }
        #expect(ids == ["a", "b", "c"])

        // First request has no pageToken; later ones carry the previous token.
        func query(_ index: Int, _ name: String) -> String? {
            URLComponents(url: transport.requests[index].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
        #expect(query(0, "pageToken") == nil)
        #expect(query(1, "pageToken") == "PAGE2")
        #expect(query(2, "pageToken") == "PAGE3")
        #expect(query(0, "q") == "trashed=false")
    }

    @Test func testEntryMappingFolderShortcutStringNumbersAndMissingParent() {
        let folder = GoogleDriveProvider.entry(from: DriveFileDTO(
            id: "d", name: "Docs", size: nil, quotaBytesUsed: nil,
            parents: ["root"], mimeType: "application/vnd.google-apps.folder",
            modifiedTime: "2026-03-04T05:06:07.123Z", md5Checksum: nil,
            ownedByMe: true, shortcutDetails: nil
        ))
        #expect(folder.isFolder)
        #expect(folder.modifiedAt != nil)

        // Numeric (not string) size still decodes; parents absent → orphan.
        let numeric = GoogleDriveProvider.entry(from: try! JSONDecoder().decode(
            DriveFileDTO.self,
            from: Data(#"{"id":"n","name":"n.bin","size":42,"quotaBytesUsed":42}"#.utf8)
        ))
        #expect(numeric.parentID == nil)
        #expect(numeric.logicalBytes == 42)
        #expect(numeric.quotaBytes == 42)
        #expect(numeric.isOwnedByMe) // defaulted true when ownedByMe absent

        // Shortcut: 0-byte leaf, target never followed.
        let shortcut = GoogleDriveProvider.entry(from: DriveFileDTO(
            id: "s", name: "link", size: nil, quotaBytesUsed: nil,
            parents: ["root"], mimeType: "application/vnd.google-apps.shortcut",
            modifiedTime: nil, md5Checksum: nil, ownedByMe: false,
            shortcutDetails: ShortcutDetailsDTO(targetId: "real", targetMimeType: "text/plain")
        ))
        #expect(!shortcut.isFolder)
        #expect(shortcut.allocatedBytes == 0)
        #expect(shortcut.isOwnedByMe == false)
    }

    @Test func testWholeSecondModifiedTimeParses() {
        #expect(GoogleDriveProvider.parseRFC3339("2026-01-02T03:04:05Z") != nil)
        #expect(GoogleDriveProvider.parseRFC3339("2026-01-02T03:04:05.987Z") != nil)
        #expect(GoogleDriveProvider.parseRFC3339("not-a-date") == nil)
    }
}
