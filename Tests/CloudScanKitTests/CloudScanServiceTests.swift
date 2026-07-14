import Testing
import Foundation
import NeodiskKit
@testable import CloudScanKit

private func makeFixture(fileCount: Int = 6, pageSize: Int = 2) -> CloudFixture {
    let files = (0..<fileCount).map { index in
        CloudFileEntry(
            id: "f\(index)",
            name: "file\(index).bin",
            parentID: "root",
            isFolder: false,
            logicalBytes: 100,
            quotaBytes: 100
        )
    }
    return CloudFixture(
        account: CloudAccount(providerID: "fixture", accountID: "demo", email: "demo@example.com"),
        quota: CloudQuota(totalBytes: 10_000, usedBytes: Int64(fileCount) * 100),
        rootFolderID: "root",
        pageSize: pageSize,
        files: files
    )
}

@Suite struct CloudScanServiceTests {
    @Test func testScanEmitsProgressPartialsAndFinished() async throws {
        let provider = FixtureCloudProvider(fixture: makeFixture())
        // Zero interval: every page yields a partial, so the test sees them.
        let service = CloudScanService(providers: [provider], partialInterval: .zero)
        let target = CloudTargetID.target(
            providerID: "fixture", accountID: "demo", displayName: "Fixture Drive"
        )!

        var partialCount = 0
        var lastMetrics: ScanMetrics?
        var finished: ScanSnapshot?
        for try await event in service.scan(target: target) {
            switch event {
            case .progress(let metrics):
                lastMetrics = metrics
            case .partial:
                #expect(finished == nil, "no partials after finished")
                partialCount += 1
            case .warning:
                break
            case .finished(let snapshot):
                finished = snapshot
            }
        }

        let snapshot = try #require(finished)
        #expect(partialCount >= 1)
        #expect(snapshot.isComplete)
        #expect(snapshot.target.id == target.id)
        #expect(snapshot.target.kind == .cloud)
        #expect(snapshot.root.allocatedSize == 600)
        #expect(snapshot.aggregateStats.fileCount == 6)
        #expect(lastMetrics?.progressFraction == 1)
        #expect(lastMetrics?.filesVisited == 6)
        #expect(lastMetrics?.bytesDiscovered == 600)
    }

    @Test func testScanFailsForUnknownAccount() async throws {
        let provider = FixtureCloudProvider(fixture: makeFixture())
        let service = CloudScanService(providers: [provider])
        let target = CloudTargetID.target(
            providerID: "fixture", accountID: "someone-else", displayName: "Other"
        )!

        await #expect(throws: CloudScanError.accountNotConnected("Other")) {
            for try await _ in service.scan(target: target) {}
        }
    }

    @Test func testScanFailsForNonCloudTarget() async throws {
        let provider = FixtureCloudProvider(fixture: makeFixture())
        let service = CloudScanService(providers: [provider])
        let target = ScanTarget(url: URL(filePath: "/tmp", directoryHint: .isDirectory))

        await #expect(throws: CloudScanError.invalidTarget(target.id)) {
            for try await _ in service.scan(target: target) {}
        }
    }

    @Test func testProgressFractionMonotonicAndCapped() {
        let first = CloudScanService.progressFraction(
            previous: 0, bytesDiscovered: 500, quotaUsedBytes: 1000
        )
        #expect(abs(first - 0.475) < 0.0001)
        // Never regresses even if quota undercounts.
        let second = CloudScanService.progressFraction(
            previous: first, bytesDiscovered: 100, quotaUsedBytes: 1000
        )
        #expect(second == first)
        // Capped below 1 until the snapshot lands.
        let overshoot = CloudScanService.progressFraction(
            previous: 0, bytesDiscovered: 5000, quotaUsedBytes: 1000
        )
        #expect(overshoot == 0.95)
        // Unknown quota: minimum visible progress only.
        let unknown = CloudScanService.progressFraction(
            previous: 0, bytesDiscovered: 5000, quotaUsedBytes: 0
        )
        #expect(unknown == 0.01)
    }

    @Test func testScanAgainstGoogleProviderBuildsTreeWithUnattributedAndSharedFile() async throws {
        // A connected account with a live token, so no refresh round-trips.
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(
                refreshToken: "r", accessToken: "access-live",
                accessTokenExpiry: Date().addingTimeInterval(3600), email: "me@example.com"
            ),
            forProviderID: "google", accountID: "perm-1"
        )
        // Drive replies in the order the service asks: quota, root, one file page.
        // usageInDrive (500) exceeds the sum of quotaBytesUsed (300) → an
        // Unattributed remainder of 200.
        let transport = FakeTransport(responses: [
            .json(200, ["storageQuota": ["limit": "10000", "usageInDrive": "500"]]),
            .json(200, ["id": "root"]),
            .json(200, ["files": [
                ["id": "docs", "name": "Docs", "parents": ["root"],
                 "mimeType": "application/vnd.google-apps.folder"],
                ["id": "a", "name": "a.pdf", "parents": ["docs"], "size": "100", "quotaBytesUsed": "100"],
                ["id": "b", "name": "b.bin", "parents": ["root"], "size": "200", "quotaBytesUsed": "200"],
                // Shared-with-me file: no parent, zero quota, not owned.
                ["id": "s", "name": "shared.txt", "size": "999",
                 "quotaBytesUsed": "0", "ownedByMe": false]
            ]])
        ])
        let provider = GoogleDriveProvider(
            configuration: GoogleOAuthConfiguration(
                clientID: "c", clientSecret: "s",
                tokenEndpoint: URL(string: "https://oauth.example.com/token")!
            ),
            transport: transport, tokenStore: store
        )
        let service = CloudScanService(providers: [provider], partialInterval: .zero)
        let target = CloudTargetID.target(
            providerID: "google", accountID: "perm-1", displayName: "Google Drive"
        )!

        var finished: ScanSnapshot?
        for try await event in service.scan(target: target) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let snapshot = try #require(finished)

        // Root totals reconcile to the reported Drive usage.
        #expect(snapshot.root.allocatedSize == 500)

        let unattributedID = CloudTargetID.nodeID(
            targetID: target.id, fileID: CloudTreeBuilder.unattributedFileID
        )
        #expect(snapshot.treeStore.node(id: unattributedID)?.allocatedSize == 200)

        // The shared 0-quota file lands (under Shared & Orphaned) with no size.
        let sharedID = CloudTargetID.nodeID(targetID: target.id, fileID: "s")
        #expect(snapshot.treeStore.node(id: sharedID)?.allocatedSize == 0)
    }

    @Test func testFixtureDecodingFromJSON() throws {
        let json = """
        {
          "account": {"providerID": "fixture", "accountID": "demo", "email": "d@e.com"},
          "displayName": "Demo Drive",
          "quota": {"totalBytes": 1000, "usedBytes": 300},
          "rootFolderID": "root",
          "files": [
            {"id": "f1", "name": "a.txt", "parentID": "root", "isFolder": false,
             "quotaBytes": 300, "modifiedAt": "2026-01-02T03:04:05Z"}
          ]
        }
        """
        let fixture = try CloudFixture.decoding(Data(json.utf8))
        #expect(fixture.quota.usedBytes == 300)
        #expect(fixture.files.count == 1)
        #expect(fixture.files[0].modifiedAt != nil)
        #expect(fixture.pageSize == nil)
        // The JSON displayName names the provider; absent it stays the default.
        #expect(FixtureCloudProvider(fixture: fixture).displayName == "Demo Drive")
        var unnamed = fixture
        unnamed.displayName = nil
        #expect(FixtureCloudProvider(fixture: unnamed).displayName == "Fixture Drive")
    }
}
