//
//  FixtureCloudProvider.swift
//  Neodisk
//
//  A CloudProvider fed from a JSON file: the NEODISK_CLOUD_FIXTURE dev hook
//  and the unit tests run the whole cloud pipeline (sidebar row, scan
//  events, visualizations, snapshot cache) without OAuth or network.
//
//  Fixture format:
//  {
//    "account":      {"providerID": "fixture", "accountID": "demo",
//                     "email": "demo@example.com"},
//    "displayName":  "Fixture Drive",   // optional sidebar subtitle
//    "quota":        {"totalBytes": 16106127360, "usedBytes": 7300000000},
//    "rootFolderID": "root",
//    "pageSize":     500,
//    "files":        [{"id": "f1", "name": "report.pdf", "parentID": "root",
//                      "isFolder": false, "quotaBytes": 12345,
//                      "modifiedAt": "2026-01-01T00:00:00Z"}, …]
//  }
//  Dates are ISO 8601. Entries may use parentID or pathComponents linkage.
//

import Foundation

public struct CloudFixture: Codable, Sendable {
    public var account: CloudAccount
    /// Sidebar subtitle for the fixture account ("Google Drive" in demos);
    /// FixtureCloudProvider falls back to "Fixture Drive" when absent.
    public var displayName: String?
    public var quota: CloudQuota
    public var rootFolderID: String
    public var pageSize: Int?
    public var files: [CloudFileEntry]

    public init(
        account: CloudAccount,
        displayName: String? = nil,
        quota: CloudQuota,
        rootFolderID: String,
        pageSize: Int? = nil,
        files: [CloudFileEntry]
    ) {
        self.account = account
        self.displayName = displayName
        self.quota = quota
        self.rootFolderID = rootFolderID
        self.pageSize = pageSize
        self.files = files
    }

    public static func decoding(_ data: Data) throws -> CloudFixture {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudFixture.self, from: data)
    }
}

public struct FixtureCloudProvider: CloudProvider {
    public let displayName: String
    private let fixture: CloudFixture

    public var providerID: String { fixture.account.providerID }

    public init(fixture: CloudFixture, displayName: String? = nil) {
        self.fixture = fixture
        self.displayName = displayName ?? fixture.displayName ?? "Fixture Drive"
    }

    public init(contentsOf url: URL, displayName: String? = nil) throws {
        self.init(
            fixture: try CloudFixture.decoding(try Data(contentsOf: url)),
            displayName: displayName
        )
    }

    public func authorize(
        openURL: @Sendable @escaping (URL) -> Void
    ) async throws -> CloudAccount {
        fixture.account
    }

    public func restoreAccounts() throws -> [CloudAccount] {
        [fixture.account]
    }

    public func signOut(_ account: CloudAccount) async throws {}

    public func quota(for account: CloudAccount) async throws -> CloudQuota {
        fixture.quota
    }

    public func rootFolderID(for account: CloudAccount) async throws -> String {
        fixture.rootFolderID
    }

    public func listAllFiles(for account: CloudAccount) -> AsyncThrowingStream<[CloudFileEntry], Error> {
        let pageSize = max(fixture.pageSize ?? 1000, 1)
        let files = fixture.files
        return AsyncThrowingStream { continuation in
            var start = 0
            while start < files.count {
                let end = min(start + pageSize, files.count)
                continuation.yield(Array(files[start..<end]))
                start = end
            }
            continuation.finish()
        }
    }
}
