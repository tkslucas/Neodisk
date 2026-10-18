import Foundation
import Testing
@testable import NeodiskKit

/// The concurrent-scan ruling matrix, pure over `ScanSourceIdentity` so no real filesystem is touched.
@Suite struct ScanSourceIdentityTests {
    private func identity(_ profile: ScanSourceProfile, device: UInt64?) -> ScanSourceIdentity {
        ScanSourceIdentity(profile: profile, deviceID: device)
    }

    @Test func testDifferentDevicesAlwaysRunBoth() {
        let running = identity(.localParallel, device: 1)
        let new = identity(.localConservative, device: 2)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: false) == .runBoth)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: true) == .runBoth)
    }

    @Test func testCloudSourceOnEitherSideRunsBoth() {
        let cloud = identity(.network, device: nil)
        let disk = identity(.localConservative, device: 7)
        // A cloud source has no local device, so it never contends with a disk
        // scan (or another cloud scan) regardless of intent.
        #expect(ScanSourceIdentity.ruling(running: cloud, new: disk, newScanIsExplicit: false) == .runBoth)
        #expect(ScanSourceIdentity.ruling(running: disk, new: cloud, newScanIsExplicit: false) == .runBoth)
        #expect(ScanSourceIdentity.ruling(running: cloud, new: cloud, newScanIsExplicit: false) == .runBoth)
    }

    @Test func testNetworkProfileRunsBothEvenOnMatchingDevice() {
        // A network mount amplifies seeks under fan-out but doesn't serialize
        // on a spindle, so two of them (or one plus a local) run together.
        let running = identity(.network, device: 5)
        let new = identity(.localConservative, device: 5)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: false) == .runBoth)
        let newNetwork = identity(.network, device: 5)
        let localRunning = identity(.localConservative, device: 5)
        #expect(ScanSourceIdentity.ruling(running: localRunning, new: newNetwork, newScanIsExplicit: false) == .runBoth)
    }

    @Test func testSameDeviceLocalParallelRunsBoth() {
        let running = identity(.localParallel, device: 9)
        let new = identity(.localParallel, device: 9)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: false) == .runBoth)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: true) == .runBoth)
    }

    @Test func testSameDeviceConservativeSerializes() {
        let running = identity(.localConservative, device: 3)
        let new = identity(.localConservative, device: 3)
        // Explicit intent wins the disk; an unsolicited refresh yields.
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: true) == .cancelOld)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: false) == .deferNew)
    }

    @Test func testSameDeviceUnsupportedSerializes() {
        let running = identity(.unsupported, device: 4)
        let new = identity(.unsupported, device: 4)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: true) == .cancelOld)
        #expect(ScanSourceIdentity.ruling(running: running, new: new, newScanIsExplicit: false) == .deferNew)
    }

    @Test func testLocalTargetDetectsADevice() {
        // The exact profile depends on the volume, but it's never nil.
        let dir = FileManager.default.temporaryDirectory
        let identity = ScanSourceIdentity.detect(for: ScanTarget(url: dir))
        #expect(identity.deviceID != nil)
    }
}
