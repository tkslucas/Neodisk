import Foundation
import Testing
import NeodiskKit
@testable import NeodiskUI

/// Without Full Disk Access, a first scan of the disk offers access before macOS stops it at a prompt per folder.
@MainActor
@Suite(.serialized) struct FullDiskAccessGateTests {
    private let disk = makeTestTarget("/", kind: .volume)

    @Test func testFirstDiskScanOffersAccessUntilScanAnyway() throws {
        let (model, service, preferences, cleanup) = try makeModel(access: .notGranted)
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

    @Test func testScansDirectlyWhenNothingWouldPrompt() throws {
        let (granted, grantedService, _, cleanupGranted) = try makeModel(access: .granted)
        defer { cleanupGranted() }
        granted.startChosenScan(disk)
        #expect(granted.fullDiskAccessGate == nil)
        #expect(grantedService.scanCount == 1)

        let (model, service, _, cleanup) = try makeModel(access: .notGranted)
        defer { cleanup() }
        model.startChosenScan(makeTestTarget("/Applications"))
        #expect(model.fullDiskAccessGate == nil)
        #expect(service.scanCount == 1)
    }

    @Test func testAccessGrantedWhileOfferedStartsTheScan() throws {
        let (model, service, preferences, cleanup) = try makeModel(access: .notGranted)
        defer { cleanup() }
        model.startChosenScan(disk)

        model.passFullDiskAccessGate(remembering: false)
        #expect(service.scanCount == 1)
        #expect(!preferences.scansWithoutFullDiskAccess)
    }

    private func makeModel(
        access: FullDiskAccessStatus
    ) throws -> (NeodiskViewModel, ControlledScanService, AppPreferences, () -> Void) {
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
        return (model, service, preferences, { removeTestDefaultsSuite(defaults, named: suite) })
    }
}
