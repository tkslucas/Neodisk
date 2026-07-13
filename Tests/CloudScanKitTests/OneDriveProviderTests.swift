import Testing
import Foundation
import NeodiskKit
@testable import CloudScanKit

private func testConfiguration() -> OneDriveOAuthConfiguration {
    OneDriveOAuthConfiguration(
        clientID: "test-client",
        authEndpoint: URL(string: "https://login.example.com/authorize")!,
        tokenEndpoint: URL(string: "https://login.example.com/token")!
    )
}

/// A connected account with a live token, so the broker serves it without a
/// refresh round-trip.
private func connectedStore(accountID: String = "user-1") -> InMemoryTokenStore {
    let store = InMemoryTokenStore()
    try! store.save(
        StoredCredentials(
            refreshToken: "refresh-1",
            accessToken: "access-live",
            accessTokenExpiry: Date().addingTimeInterval(3600),
            email: "me@example.com"
        ),
        forProviderID: "onedrive", accountID: accountID
    )
    return store
}

private func connectedAccount(_ accountID: String = "user-1") -> CloudAccount {
    CloudAccount(providerID: "onedrive", accountID: accountID, email: "me@example.com")
}

/// A lock-guarded slot so the @Sendable openURL closure can hand the auth URL
/// back to the test body.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func set(_ url: URL) { lock.withLock { value = url } }
    var url: URL? { lock.withLock { value } }
}

@Suite(.serialized) struct OneDriveProviderTests {
    // MARK: - Authorization

    @Test func testAuthorizeExchangesCodeFetchesIdentityAndStores() async throws {
        // Token exchange (with a rotated refresh token), then the /me identity
        // lookup. mail is null → email falls back to userPrincipalName.
        let transport = FakeTransport(responses: [
            .json(200, [
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_in": 3600,
                "token_type": "Bearer"
            ]),
            .json(200, [
                "id": "user-123",
                "mail": NSNull(),
                "userPrincipalName": "me@contoso.onmicrosoft.com"
            ])
        ])
        let store = InMemoryTokenStore()
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )

        // The stub browser: read the loopback redirect + state out of the auth
        // URL and immediately hit the loopback server with a matching code.
        let capturedAuthURL = URLBox()
        let account = try await provider.authorize { url in
            capturedAuthURL.set(url)
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

        #expect(account.accountID == "user-123")
        #expect(account.email == "me@contoso.onmicrosoft.com")
        #expect(account.providerID == "onedrive")

        // The scope requested at the consent screen carries offline_access, so
        // Microsoft returns a refresh token.
        let authURL = try #require(capturedAuthURL.url)
        let scope = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value
        #expect(scope?.contains("offline_access") == true)

        // Public client: no client_secret in the token exchange body.
        #expect(transport.bodies[0].contains("client_secret") == false)
        #expect(transport.bodies[0].contains("code_verifier")) // PKCE, not a secret

        let stored = try store.load(forProviderID: "onedrive", accountID: "user-123")
        #expect(stored?.refreshToken == "refresh-1")
        #expect(stored?.email == "me@contoso.onmicrosoft.com")
    }

    @Test func testAuthorizePrefersMailOverUserPrincipalName() async throws {
        let transport = FakeTransport(responses: [
            .json(200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600]),
            .json(200, ["id": "u", "mail": "primary@example.com",
                        "userPrincipalName": "u@contoso.onmicrosoft.com"])
        ])
        let store = InMemoryTokenStore()
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )
        let account = try await provider.authorize { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value,
                  var callback = URLComponents(string: redirect) else { return }
            callback.queryItems = [
                URLQueryItem(name: "code", value: "c"),
                URLQueryItem(name: "state", value: state)
            ]
            let target = callback.url!
            Task { _ = try? await URLSession.shared.data(from: target) }
        }
        #expect(account.email == "primary@example.com")
    }

    @Test func testAuthorizeThrowsWhenNotConfigured() async throws {
        let provider = OneDriveProvider(
            configuration: OneDriveOAuthConfiguration(clientID: ""),
            transport: FakeTransport(responses: []),
            tokenStore: InMemoryTokenStore()
        )
        await #expect(throws: OneDriveError.notConfigured) {
            _ = try await provider.authorize { _ in }
        }
    }

    @Test func testRestoreAndSignOutRoundTrip() async throws {
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(refreshToken: "r", accessToken: "a", email: "me@example.com"),
            forProviderID: "onedrive", accountID: "user-1"
        )
        // No revoke endpoint: sign-out issues no HTTP, just deletes credentials.
        let transport = FakeTransport(responses: [])
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )

        let accounts = try provider.restoreAccounts()
        #expect(accounts.map(\.accountID) == ["user-1"])
        #expect(accounts.first?.email == "me@example.com")

        try await provider.signOut(accounts[0])
        #expect(try provider.restoreAccounts().isEmpty)
        // Nothing was sent over the wire — no public-client revocation endpoint.
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Rotated refresh token

    @Test func testRefreshPersistsMicrosoftRotatedRefreshToken() async throws {
        // Microsoft rotates the refresh token on every refresh; the new one
        // must be persisted or the next launch reconnects with a dead token.
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(
                refreshToken: "refresh-old",
                accessToken: "stale",
                accessTokenExpiry: Date().addingTimeInterval(-3600) // expired → forces refresh
            ),
            forProviderID: "onedrive", accountID: "user-1"
        )
        // Refresh response carries a rotated refresh token, then the quota GET.
        let transport = FakeTransport(responses: [
            .json(200, [
                "access_token": "access-new",
                "refresh_token": "refresh-rotated",
                "expires_in": 3600,
                "token_type": "Bearer"
            ]),
            .json(200, ["quota": ["total": 1000, "used": 100]])
        ])
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )
        _ = try await provider.quota(for: connectedAccount())

        let stored = try store.load(forProviderID: "onedrive", accountID: "user-1")
        #expect(stored?.refreshToken == "refresh-rotated")
        #expect(stored?.accessToken == "access-new")
    }

    // MARK: - Quota

    @Test func testQuotaMapsUsedToBothDriveAndAccountFigures() async throws {
        let transport = FakeTransport(responses: [
            .json(200, ["quota": ["total": 5368709120, "used": 1073741824]])
        ])
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        let quota = try await provider.quota(for: connectedAccount())
        #expect(quota.totalBytes == 5368709120)
        #expect(quota.usedBytes == 1073741824)
        // OneDrive has no Gmail/Photos-style split, so account usage == drive.
        #expect(quota.accountUsedBytes == 1073741824)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
    }

    @Test func testQuotaTreatsZeroOrAbsentTotalAsUnlimited() async throws {
        let zeroTotal = FakeTransport(responses: [.json(200, ["quota": ["total": 0, "used": 42]])])
        let provider1 = OneDriveProvider(
            configuration: testConfiguration(), transport: zeroTotal, tokenStore: connectedStore()
        )
        let q1 = try await provider1.quota(for: connectedAccount())
        #expect(q1.totalBytes == nil)
        #expect(q1.usedBytes == 42)

        let absentTotal = FakeTransport(responses: [.json(200, ["quota": ["used": 7]])])
        let provider2 = OneDriveProvider(
            configuration: testConfiguration(), transport: absentTotal, tokenStore: connectedStore()
        )
        let q2 = try await provider2.quota(for: connectedAccount())
        #expect(q2.totalBytes == nil)
        #expect(q2.usedBytes == 7)
    }

    @Test func testRootFolderID() async throws {
        let transport = FakeTransport(responses: [.json(200, ["id": "01ROOT"])])
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )
        #expect(try await provider.rootFolderID(for: connectedAccount()) == "01ROOT")
    }

    // MARK: - Delta paging

    @Test func testListAllFilesFollowsNextLinkAndStopsAtDeltaLink() async throws {
        let transport = FakeTransport(responses: [
            .json(200, [
                "value": [["id": "a", "name": "a.txt", "size": 10,
                           "parentReference": ["id": "root"], "file": [:]]],
                "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=PAGE2"
            ]),
            .json(200, [
                "value": [["id": "b", "name": "b.txt", "size": 20,
                           "parentReference": ["id": "root"], "file": [:]]],
                // deltaLink present → enumeration is complete; must NOT follow.
                "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=FINAL"
            ])
        ])
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: connectedStore()
        )

        var ids: [String] = []
        for try await page in provider.listAllFiles(for: connectedAccount()) {
            ids.append(contentsOf: page.map(\.id))
        }
        #expect(ids == ["a", "b"])
        // Two GETs: initial delta + the nextLink page. The deltaLink is never
        // fetched, so no third request.
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].url?.absoluteString.contains("PAGE2") == true)
    }

    // MARK: - Mapping

    @Test func testEntryMappingSkipsDeletedNilsFolderSizePicksQuickXor() {
        // Tombstone: an item bearing a `deleted` facet is dropped.
        let deleted = OneDriveProvider.entry(from: try! JSONDecoder().decode(
            DriveItemDTO.self,
            from: Data(#"{"id":"gone","deleted":{"state":"deleted"}}"#.utf8)
        ))
        #expect(deleted == nil)

        // Folder: `size` is a descendant aggregate and must be nil'd so the
        // builder rolls up from children instead of double-counting.
        let folder = OneDriveProvider.entry(from: try! JSONDecoder().decode(
            DriveItemDTO.self,
            from: Data(#"{"id":"d","name":"Docs","size":999,"parentReference":{"id":"root"},"folder":{"childCount":3}}"#.utf8)
        ))!
        #expect(folder.isFolder)
        #expect(folder.logicalBytes == nil)
        #expect(folder.quotaBytes == nil)
        #expect(folder.parentID == "root")

        // Package (e.g. a OneNote notebook) is folder-like → treated as folder.
        let package = OneDriveProvider.entry(from: try! JSONDecoder().decode(
            DriveItemDTO.self,
            from: Data(#"{"id":"p","name":"Notebook","size":500,"package":{"type":"oneNote"}}"#.utf8)
        ))!
        #expect(package.isFolder)
        #expect(package.logicalBytes == nil)

        // File: size maps to both logical and quota; quickXorHash preferred
        // over sha256Hash; mimeType becomes the kind hint.
        let file = OneDriveProvider.entry(from: try! JSONDecoder().decode(
            DriveItemDTO.self,
            from: Data(#"""
            {"id":"f","name":"report.pdf","size":123,"parentReference":{"id":"d"},
             "lastModifiedDateTime":"2026-03-04T05:06:07.123Z",
             "file":{"mimeType":"application/pdf","hashes":{"quickXorHash":"QXOR","sha256Hash":"SHA"}}}
            """#.utf8)
        ))!
        #expect(!file.isFolder)
        #expect(file.logicalBytes == 123)
        #expect(file.quotaBytes == 123)
        #expect(file.contentHash == "QXOR")
        #expect(file.kindHint == "application/pdf")
        #expect(file.modifiedAt != nil)
        #expect(file.isOwnedByMe)

        // sha256 used only when quickXor absent.
        let sha = OneDriveProvider.entry(from: try! JSONDecoder().decode(
            DriveItemDTO.self,
            from: Data(#"{"id":"g","name":"x.bin","size":1,"file":{"hashes":{"sha256Hash":"ONLYSHA"}}}"#.utf8)
        ))!
        #expect(sha.contentHash == "ONLYSHA")
    }

    @Test func testWholeSecondModifiedTimeParses() {
        #expect(OneDriveProvider.parseISO8601("2026-01-02T03:04:05Z") != nil)
        #expect(OneDriveProvider.parseISO8601("2026-01-02T03:04:05.987Z") != nil)
        #expect(OneDriveProvider.parseISO8601("not-a-date") == nil)
    }

    // MARK: - End-to-end scan

    @Test func testScanBuildsTreeWithoutDoubleCountingFolderSizes() async throws {
        let store = connectedStore()
        // Service asks in order: quota, root, delta. usage 300 == Σ file sizes
        // so nothing is Unattributed; the docs folder reports an aggregate
        // size (300) that must be ignored in favor of its one 100-byte child.
        let transport = FakeTransport(responses: [
            .json(200, ["quota": ["total": 10000, "used": 300]]),
            .json(200, ["id": "root"]),
            .json(200, [
                "value": [
                    // The root item comes back with id == rootFolderID; the
                    // builder skips it.
                    ["id": "root", "name": "root", "folder": ["childCount": 2]],
                    ["id": "docs", "name": "Docs", "size": 300,
                     "parentReference": ["id": "root"], "folder": ["childCount": 1]],
                    ["id": "a", "name": "a.pdf", "size": 100,
                     "parentReference": ["id": "docs"], "file": [:]],
                    ["id": "b", "name": "b.bin", "size": 200,
                     "parentReference": ["id": "root"], "file": [:]]
                ],
                "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=FINAL"
            ])
        ])
        let provider = OneDriveProvider(
            configuration: testConfiguration(), transport: transport, tokenStore: store
        )
        let service = CloudScanService(providers: [provider], partialInterval: .zero)
        let target = CloudTargetID.target(
            providerID: "onedrive", accountID: "user-1", displayName: "OneDrive"
        )!

        var finished: ScanSnapshot?
        for try await event in service.scan(target: target) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let snapshot = try #require(finished)

        // Root reconciles to the sum of file sizes (100 + 200), with no
        // Unattributed remainder and no folder-aggregate double count.
        #expect(snapshot.root.allocatedSize == 300)
        #expect(snapshot.aggregateStats.fileCount == 2)

        // The Docs folder totals only its 100-byte child, not its reported 300.
        let docsID = CloudTargetID.nodeID(targetID: target.id, fileID: "docs")
        #expect(snapshot.treeStore.node(id: docsID)?.allocatedSize == 100)
    }
}
