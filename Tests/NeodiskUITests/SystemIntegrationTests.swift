import AppKit
import Testing
import Foundation
import NeodiskKit
@testable import NeodiskUI

@Suite struct SystemIntegrationTests {
    @Test func testOpenThrowsWhenWorkspaceDeclinesURL() throws {
        let url = URL(filePath: "/tmp/missing.txt")
        let workspace = WorkspaceSpy(openResult: false)

        let error: any Error = try #require(throws: (any Error).self) {
            try SystemIntegration.open(url, workspace: workspace)
        }
        do {
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                Issue.record("Expected SystemIntegrationError, got \(error).")
                return
            }

            guard case .openFailed(let path) = integrationError else {
                Issue.record("Expected openFailed, got \(integrationError).")
                return
            }

            #expect(path == url.path)
            #expect(error.localizedDescription == "macOS could not open the item at \(url.path).")
        }
        #expect(workspace.openedURLs == [url])
    }

    @Test func webSearchEncodesEverythingButUnreservedCharacters() throws {
        let url = try #require(SystemIntegration.webSearchURL(for: "c++ notes & 50% #1/é.txt"))
        #expect(url.absoluteString
            == "https://www.google.com/search?q=c%2B%2B%20notes%20%26%2050%25%20%231%2F%C3%A9.txt")
    }

    @Test func searchWebOpensTheSearchInTheDefaultBrowser() {
        let workspace = WorkspaceSpy(openResult: true)
        SystemIntegration.searchWeb(for: "Movies", workspace: workspace)
        #expect(workspace.openedURLs.map(\.absoluteString) == ["https://www.google.com/search?q=Movies"])
    }

    @Test func testRevealSelectsRequestedURL() {
        let url = URL(filePath: "/tmp/example.txt")
        let workspace = WorkspaceSpy(openResult: true)

        SystemIntegration.reveal(url, workspace: workspace)

        #expect(workspace.revealedSelections == [[url]])
    }

    @Test func testRevealSelectsRequestedURLs() {
        let urls = [
            URL(filePath: "/tmp/first.txt"),
            URL(filePath: "/tmp/second.txt")
        ]
        let workspace = WorkspaceSpy(openResult: true)

        SystemIntegration.reveal(urls, workspace: workspace)

        #expect(workspace.revealedSelections == [urls])
    }

    @Test func testCopyPathWritesPathAndFileURLToPasteboard() throws {
        let url = URL(filePath: "/tmp/example.txt")
        let pasteboard = PasteboardSpy()

        try SystemIntegration.copyPath(url, pasteboard: pasteboard)

        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writtenStrings[.string] == url.path)
        #expect(pasteboard.writtenStrings[.fileURL] == url.absoluteString)
    }

    @Test func testCopyPathThrowsWhenPasteboardRejectsARepresentation() throws {
        let url = URL(filePath: "/tmp/example.txt")
        let pasteboard = PasteboardSpy(rejectedTypes: [.fileURL])

        let error: any Error = try #require(throws: (any Error).self) {
            try SystemIntegration.copyPath(url, pasteboard: pasteboard)
        }
        do {
            guard let integrationError = error as? SystemIntegration.SystemIntegrationError else {
                Issue.record("Expected SystemIntegrationError, got \(error).")
                return
            }

            guard case .copyPathFailed(let path) = integrationError else {
                Issue.record("Expected copyPathFailed, got \(integrationError).")
                return
            }

            #expect(path == url.path)
        }
        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writtenStrings[.string] == url.path)
        #expect(pasteboard.writtenStrings[.fileURL] == url.absoluteString)
    }

    @Test func testCopyPathsWritesNewlineSeparatedPaths() throws {
        let urls = [
            URL(filePath: "/tmp/first.txt"),
            URL(filePath: "/tmp/second.txt")
        ]
        let pasteboard = PasteboardSpy()

        try SystemIntegration.copyPaths(urls, pasteboard: pasteboard)

        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.writtenStrings[.string] == "/tmp/first.txt\n/tmp/second.txt")
        #expect(pasteboard.writtenStrings[.fileURL] == nil)
    }

    @Test func testFullDiskAccessStatusUsesInjectedProbes() {
        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [nil], evidence: [])
            ) == .unknown)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [nil], evidence: [successfulProbe, successfulProbe])
            ) == .notGranted)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [failedProbe], evidence: [successfulProbe, successfulProbe])
            ) == .notGranted)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [successfulProbe], evidence: [successfulProbe, failedProbe])
            ) == .notGranted)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [successfulProbe], evidence: [successfulProbe, successfulProbe])
            ) == .granted)
    }

    @Test func testFullDiskAccessStatusKeepsLegacyLogicBeforeMacOS27() {
        // Pre-27 the user TCC gatekeeper rules regardless of other evidence.
        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [nil], evidence: [successfulProbe, successfulProbe])
            ) == .notGranted)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 26,
                probes: .init(gatekeepers: [successfulProbe], evidence: [successfulProbe, successfulProbe])
            ) == .granted)
    }

    @Test func testFullDiskAccessStatusUsesMacOS27PrimarySentinels() {
        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                probes: .init(gatekeepers: [successfulProbe, successfulProbe], evidence: [nil])
            ) == .granted)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                probes: .init(gatekeepers: [successfulProbe, failedProbe], evidence: [successfulProbe])
            ) == .notGranted)
    }

    @Test func testFullDiskAccessStatusUsesMacOS27SystemTCCOnlyAsFallbackEvidence() {
        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                probes: .init(gatekeepers: [successfulProbe, nil], evidence: [successfulProbe])
            ) == .granted)

        #expect(SystemIntegration.fullDiskAccessStatus(
                macOSMajorVersion: 27,
                probes: .init(gatekeepers: [successfulProbe, nil], evidence: [failedProbe])
            ) == .unknown)
    }

    private var successfulProbe: SystemIntegration.FullDiskAccessProbe {
        {}
    }

    private var failedProbe: SystemIntegration.FullDiskAccessProbe {
        {
            throw NSError(domain: "NeodiskTests", code: 1)
        }
    }
}

private final class WorkspaceSpy: SystemWorkspace {
    private let openResult: Bool
    private(set) var openedURLs: [URL] = []
    private(set) var revealedSelections: [[URL]] = []

    init(openResult: Bool) {
        self.openResult = openResult
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealedSelections.append(fileURLs)
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openResult
    }
}

private final class PasteboardSpy: PathPasteboard {
    private let rejectedTypes: Set<NSPasteboard.PasteboardType>
    private(set) var clearCount = 0
    private(set) var writtenStrings: [NSPasteboard.PasteboardType: String] = [:]

    init(rejectedTypes: Set<NSPasteboard.PasteboardType> = []) {
        self.rejectedTypes = rejectedTypes
    }

    @discardableResult
    func clearContents() -> Int {
        clearCount += 1
        return clearCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writtenStrings[dataType] = string
        return !rejectedTypes.contains(dataType)
    }
}
