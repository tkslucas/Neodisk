import Testing
import Foundation
import NeodiskKit
@testable import CloudScanKit

@Suite(.serialized) struct DropboxScanTests {
    @Test func testScanBuildsTreeWithPathLinkedFoldersAndTotals() async throws {
        // A connected account with a live token, so no refresh round-trips.
        let store = InMemoryTokenStore()
        try store.save(
            StoredCredentials(
                refreshToken: "r", accessToken: "access-live",
                accessTokenExpiry: Date().addingTimeInterval(3600), email: "me@example.com"
            ),
            forProviderID: "dropbox", accountID: "dbid:1"
        )

        // Dropbox replies in the order the service asks: get_space_usage, then
        // the recursive list_folder (rootFolderID needs no network). The listing
        // path-links entries; "/Docs/a.txt" must land under the explicit Docs
        // folder, and "/nested/deep/c.bin" under a synthesized "deep" folder.
        let transport = FakeTransport(responses: [
            .json(200, ["used": 300, "allocation": [".tag": "individual", "allocated": 1000]]),
            .json(200, [
                "entries": [
                    [".tag": "folder", "id": "id:docs", "name": "Docs",
                     "path_display": "/Docs", "path_lower": "/docs"],
                    [".tag": "file", "id": "id:a", "name": "a.txt",
                     "path_display": "/Docs/a.txt", "path_lower": "/docs/a.txt", "size": 100],
                    [".tag": "file", "id": "id:b", "name": "b.bin",
                     "path_display": "/b.bin", "path_lower": "/b.bin", "size": 150],
                    // Intermediate folders /nested and /nested/deep are absent
                    // from the listing and must be synthesized.
                    [".tag": "file", "id": "id:c", "name": "c.bin",
                     "path_display": "/nested/deep/c.bin", "path_lower": "/nested/deep/c.bin", "size": 50]
                ],
                "cursor": "c1",
                "has_more": false
            ])
        ])
        let provider = DropboxProvider(
            configuration: DropboxOAuthConfiguration(clientID: "app-key"),
            transport: transport, tokenStore: store
        )
        let service = CloudScanService(providers: [provider], partialInterval: .zero)
        let target = CloudTargetID.target(
            providerID: "dropbox", accountID: "dbid:1", displayName: "Dropbox"
        )!

        var finished: ScanSnapshot?
        for try await event in service.scan(target: target) {
            if case .finished(let snapshot) = event { finished = snapshot }
        }
        let snapshot = try #require(finished)

        // Root totals reconcile to the reported usage (100 + 150 + 50 = 300),
        // so there is no Unattributed remainder.
        #expect(snapshot.root.allocatedSize == 300)
        let unattributedID = CloudTargetID.nodeID(
            targetID: target.id, fileID: CloudTreeBuilder.unattributedFileID
        )
        #expect(snapshot.treeStore.node(id: unattributedID) == nil)

        // a.txt sits under the explicit Docs folder, which rolls up to 100.
        let docsID = CloudTargetID.nodeID(targetID: target.id, fileID: "id:docs")
        let docs = try #require(snapshot.treeStore.node(id: docsID))
        #expect(docs.isDirectory)
        #expect(docs.allocatedSize == 100)
        #expect(snapshot.treeStore.children(of: docsID).map(\.name) == ["a.txt"])

        // c.bin sits under a synthesized "nested/deep" chain that rolls up to 50.
        let deepID = CloudTargetID.nodeID(
            targetID: target.id, fileID: CloudTreeBuilder.pathFolderIDPrefix + "nested/deep"
        )
        let deep = try #require(snapshot.treeStore.node(id: deepID))
        #expect(deep.name == "deep")
        #expect(deep.allocatedSize == 50)
    }
}
