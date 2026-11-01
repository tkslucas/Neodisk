import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Without Full Disk Access, a first scan of the disk offers access before macOS stops it at a prompt per folder.
@MainActor
@Suite(.serialized) struct FullDiskAccessGateTests {
    private let disk = makeTestTarget("/", kind: .volume)

    @Test func testFirstDiskScanOffersAccessUntilScanAnyway() async throws {
        let (model, service, preferences, cleanup) = try await makeModel(access: .notGranted)
        defer { cleanup() }

        model.startChosenScan(disk)
        #expect(model.fullDiskAccessGate?.id == disk.id)
        #expect(service.scanCount == 0)

        model.passFullDiskAccessGate(remembering: true)
        #expect(model.fullDiskAccessGate == nil)
        #expect(service.scanCount == 1)
        #expect(preferences.scansWithoutFullDiskAccess)

        // Chosen once: the next first scan goes straight ahead.
        model.stopScan()
        model.startChosenScan(makeTestTarget(NSHomeDirectory()))
        #expect(model.fullDiskAccessGate == nil)
        #expect(service.scanCount == 2)
    }

    @Test func testScansDirectlyWhenNothingWouldPrompt() async throws {
        let (granted, grantedService, _, cleanupGranted) = try await makeModel(access: .granted)
        defer { cleanupGranted() }
        granted.startChosenScan(disk)
        #expect(granted.fullDiskAccessGate == nil)
        #expect(grantedService.scanCount == 1)

        let (model, service, _, cleanup) = try await makeModel(access: .notGranted)
        defer { cleanup() }
        model.startChosenScan(makeTestTarget("/Applications"))
        #expect(model.fullDiskAccessGate == nil)
        #expect(service.scanCount == 1)
    }

    @Test func testAccessGrantedWhileOfferedStartsTheScan() async throws {
        let (model, service, preferences, cleanup) = try await makeModel(access: .notGranted)
        defer { cleanup() }
        model.startChosenScan(disk)

        model.passFullDiskAccessGate(remembering: false)
        #expect(service.scanCount == 1)
        #expect(!preferences.scansWithoutFullDiskAccess)
    }

    /// The offer covers the scan on screen, so Rescan can't reach past it to the previous location (F51).
    @Test func testRescanWaitsWhileAccessIsOffered() async throws {
        let (model, service, _, cleanup) = try await makeModel(access: .notGranted)
        defer { cleanup() }
        let applications = makeTestTarget("/Applications")
        model.startScan(applications)
        let file = makeTestFileNode(id: "/Applications/file.txt", name: "file.txt", size: 20)
        let root = makeTestDirectoryNode(id: applications.id, name: applications.displayName, children: [file])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [file]])
        service.yield(.finished(makeTestSnapshot(target: applications, root: root, store: store)), scanIndex: 0)
        service.finish(scanIndex: 0)
        try await waitUntil("first scan shown") { model.coordinator.snapshot != nil && !model.coordinator.isScanning }
        #expect(model.canRescan)

        model.startChosenScan(disk)
        #expect(model.fullDiskAccessGate?.id == disk.id)
        #expect(!model.canRescan)
        model.rescan()
        #expect(service.scanCount == 1)
        #expect(model.fullDiskAccessGate?.id == disk.id)
    }

    /// Waits for the snapshot index: until it loads, a location may have a scan the model can't see yet.
    private func makeModel(
        access: FullDiskAccessStatus
    ) async throws -> (NeodiskViewModel, ControlledScanService, AppPreferences, () -> Void) {
        let suite = "NeodiskFDAGateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = ControlledScanService()
        let model = NeodiskViewModel(
            coordinator: ScanCoordinator(scanService: service),
            snapshotCache: makeIsolatedCache(),
            sidebarFolderStore: SidebarFolderStore(defaults: defaults)
        )
        let preferences = AppPreferences(defaults: defaults)
        model.preferences = preferences
        model.warnings.fullDiskAccessStatus = access
        try await waitUntil("snapshot index loaded") { model.session.hasIndexedSnapshotCache }
        return (model, service, preferences, { removeTestDefaultsSuite(defaults, named: suite) })
    }
}
