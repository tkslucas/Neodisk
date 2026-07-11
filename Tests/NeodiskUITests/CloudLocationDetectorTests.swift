import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

@Suite struct CloudLocationDetectorTests {
    private let cloudStorageRoot = URL(fileURLWithPath: "/Users/tester/Library/CloudStorage", isDirectory: true)
    private let iCloudDocuments = URL(
        fileURLWithPath: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs",
        isDirectory: true
    )

    @Test func testKnownProviderFolderNamesGetFriendlyNames() {
        #expect(CloudLocationDetector.providerName(forFolderName: "GoogleDrive-me@gmail.com") == "Google Drive")
        #expect(CloudLocationDetector.providerName(forFolderName: "Dropbox") == "Dropbox")
        #expect(CloudLocationDetector.providerName(forFolderName: "Dropbox-Personal") == "Dropbox")
        #expect(CloudLocationDetector.providerName(forFolderName: "OneDrive-Contoso") == "OneDrive")
        #expect(CloudLocationDetector.providerName(forFolderName: "Box-Box") == "Box")
    }

    @Test func testUnknownProviderFallsBackToFolderPrefix() {
        #expect(CloudLocationDetector.providerName(forFolderName: "Nextcloud-cloud.example.com") == "Nextcloud")
        #expect(CloudLocationDetector.providerName(forFolderName: "pCloud Drive") == "pCloud Drive")
    }

    @Test func testICloudDriveComesFirstAndProvidersAreSorted() {
        let targets = CloudLocationDetector.targets(
            iCloudDriveDocumentsURL: iCloudDocuments,
            cloudStorageRootURL: cloudStorageRoot,
            providerFolderNames: ["OneDrive-Personal", "Dropbox"],
            legacyDropboxURL: nil
        )

        #expect(targets.map(\.displayName) == ["iCloud Drive", "Dropbox", "OneDrive"])
        #expect(targets.allSatisfy { $0.kind == .folder })
        #expect(targets[0].url == iCloudDocuments)
        #expect(targets[1].url.path.hasSuffix("/CloudStorage/Dropbox"))
    }

    @Test func testMultipleAccountsOfOneProviderKeepTheirSuffix() {
        let targets = CloudLocationDetector.targets(
            iCloudDriveDocumentsURL: nil,
            cloudStorageRootURL: cloudStorageRoot,
            providerFolderNames: ["GoogleDrive-work@company.com", "GoogleDrive-me@gmail.com", "Dropbox"],
            legacyDropboxURL: nil
        )

        #expect(targets.map(\.displayName) == [
            "Dropbox",
            "Google Drive (me@gmail.com)",
            "Google Drive (work@company.com)",
        ])
    }

    @Test func testSingleAccountDropsTheSuffix() {
        let targets = CloudLocationDetector.targets(
            iCloudDriveDocumentsURL: nil,
            cloudStorageRootURL: cloudStorageRoot,
            providerFolderNames: ["GoogleDrive-me@gmail.com"],
            legacyDropboxURL: nil
        )

        #expect(targets.map(\.displayName) == ["Google Drive"])
    }

    @Test func testLegacyDropboxFolderIsAppended() {
        let legacyDropbox = URL(fileURLWithPath: "/Users/tester/Dropbox", isDirectory: true)
        let targets = CloudLocationDetector.targets(
            iCloudDriveDocumentsURL: nil,
            cloudStorageRootURL: cloudStorageRoot,
            providerFolderNames: [],
            legacyDropboxURL: legacyDropbox
        )

        #expect(targets.map(\.displayName) == ["Dropbox"])
        #expect(targets[0].url == legacyDropbox)
    }

    @Test func testNoCloudLocationsYieldsNoTargets() {
        let targets = CloudLocationDetector.targets(
            iCloudDriveDocumentsURL: nil,
            cloudStorageRootURL: cloudStorageRoot,
            providerFolderNames: [],
            legacyDropboxURL: nil
        )

        #expect(targets.isEmpty)
    }

    @Test func testDeduplicateDropsLegacyDropboxSymlinkIntoFileProvider() throws {
        // A legacy ~/Dropbox that is only a symlink into ~/Library/CloudStorage
        // normalizes to the provider folder's path, so the sidebar's cloud
        // section must show a single Dropbox entry.
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appending(path: "neodisk-cloud-dedup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cloudRoot = base.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let providerFolder = cloudRoot.appending(path: "Dropbox", directoryHint: .isDirectory)
        let legacyDropbox = base.appending(path: "Dropbox", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: providerFolder, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: legacyDropbox, withDestinationURL: providerFolder)
        defer { try? fileManager.removeItem(at: base) }

        let targets = SystemIntegration.deduplicate(CloudLocationDetector.targets(
            iCloudDriveDocumentsURL: nil,
            cloudStorageRootURL: cloudRoot,
            providerFolderNames: ["Dropbox"],
            legacyDropboxURL: legacyDropbox
        ))

        #expect(targets.map(\.displayName) == ["Dropbox"])
    }

    @Test func testDeduplicateKeepsFirstOccurrenceAndOrder() {
        func target(_ path: String, name: String) -> ScanTarget {
            ScanTarget(
                id: path,
                url: URL(fileURLWithPath: path, isDirectory: true),
                displayName: name,
                kind: .folder
            )
        }

        let deduplicated = SystemIntegration.deduplicate([
            target("/Users/tester/Library/CloudStorage/Dropbox", name: "Dropbox"),
            target("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs", name: "iCloud Drive"),
            target("/Users/tester/Library/CloudStorage/Dropbox", name: "Dropbox (legacy)"),
        ])

        #expect(deduplicated.map(\.displayName) == ["Dropbox", "iCloud Drive"])
    }

    @Test func testIsCloudPathMatchesOnlyCloudRootDescendants() {
        let cloudStoragePath = ScanOptions.defaultCloudStorageRootPath
        let iCloudPath = ScanOptions.defaultICloudDriveRootPath

        #expect(CloudLocationDetector.isCloudPath("\(cloudStoragePath)/GoogleDrive-me@gmail.com"))
        #expect(CloudLocationDetector.isCloudPath("\(iCloudPath)/com~apple~CloudDocs"))
        #expect(!CloudLocationDetector.isCloudPath(cloudStoragePath))
        #expect(!CloudLocationDetector.isCloudPath("/Users/tester/Documents"))
    }
}
