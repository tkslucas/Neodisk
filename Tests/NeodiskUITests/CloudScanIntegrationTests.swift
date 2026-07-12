import Testing
import Foundation
import NeodiskKit
@testable import NeodiskUI

/// The NeodiskUI-side CloudScan glue: the routing scan service and the view
/// model's connected-account plumbing. The cloud engine itself lives in
/// CloudScanKit and is tested there; these fakes stand in for it so the tests
/// stay independent of that (excludable) dependency.
@Suite struct CloudScanIntegrationTests {
    @MainActor
    @Test func testRoutesCloudTargetToCloudLeg() async throws {
        let local = RecordingStreamService()
        let cloud = RecordingStreamService()
        let service = RoutingScanService(localService: local, cloudService: cloud)

        try await drain(service.scan(target: makeCloudTarget(), options: ScanOptions()))

        #expect(cloud.recordedTargetIDs == [makeCloudTarget().id])
        #expect(local.recordedTargetIDs.isEmpty)
    }

    @MainActor
    @Test func testRoutesFolderTargetToLocalLeg() async throws {
        let local = RecordingStreamService()
        let cloud = RecordingStreamService()
        let service = RoutingScanService(localService: local, cloudService: cloud)
        let folder = makeTestTarget("/scan/local")

        try await drain(service.scan(target: folder, options: ScanOptions()))

        #expect(local.recordedTargetIDs == [folder.id])
        #expect(cloud.recordedTargetIDs.isEmpty)
    }

    @MainActor
    @Test func testCloudTargetWithoutCloudLegThrowsUnavailable() async throws {
        let local = RecordingStreamService()
        let service = RoutingScanService(localService: local, cloudService: nil)

        await #expect(throws: CloudScanUnavailableError.self) {
            try await drain(service.scan(target: makeCloudTarget(), options: ScanOptions()))
        }
        #expect(local.recordedTargetIDs.isEmpty)
    }

    @MainActor
    @Test func testViewModelExposesCloudAccountsInBuiltInLocations() throws {
        let account = makeCloudTarget()
        let cloudScan = FakeCloudScanIntegration(
            accountTargets: [account],
            subtitles: [account.id: "Fixture Drive"]
        )
        let environment = try IsolatedModelEnvironment()
        defer { environment.tearDown() }

        let model = environment.makeModel(cloudScan: cloudScan)

        #expect(model.cloudDriveAccounts.map(\.id) == [account.id])
        #expect(model.builtInLocations.contains { $0.id == account.id })
        #expect(model.cloudScan?.accountSubtitle(forTargetID: account.id) == "Fixture Drive")
    }

    @MainActor
    @Test func testConnectRefreshesCloudDriveAccounts() async throws {
        let cloudScan = FakeCloudScanIntegration(
            accountTargets: [],
            subtitles: [:],
            connectMenu: [(id: "google", title: "Connect Google Drive…")]
        )
        let environment = try IsolatedModelEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel(cloudScan: cloudScan)

        #expect(model.cloudDriveAccounts.isEmpty)
        #expect(model.cloudScan?.canConnectAccounts == true)

        let connected = makeCloudTarget()
        cloudScan.nextConnectResult = connected
        model.connectCloudAccount(providerID: "google")

        try await eventually { model.cloudDriveAccounts.map(\.id) == [connected.id] }
        #expect(model.cloudDriveAccounts.map(\.id) == [connected.id])
    }

    @MainActor
    @Test func testSignOutRemovesCloudAccount() async throws {
        let account = makeCloudTarget()
        let cloudScan = FakeCloudScanIntegration(
            accountTargets: [account],
            subtitles: [account.id: "Google Drive"],
            connectMenu: [(id: "google", title: "Connect Google Drive…")]
        )
        let environment = try IsolatedModelEnvironment()
        defer { environment.tearDown() }
        let model = environment.makeModel(cloudScan: cloudScan)

        #expect(model.cloudDriveAccounts.map(\.id) == [account.id])

        model.signOutCloudAccount(targetID: account.id)

        try await eventually { model.cloudDriveAccounts.isEmpty }
        #expect(model.cloudDriveAccounts.isEmpty)
        #expect(model.cachedScanInfo[account.id] == nil)
    }
}

/// Polls a MainActor condition, yielding between checks, until it holds or the
/// budget runs out.
@MainActor
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

private func makeCloudTarget() -> ScanTarget {
    ScanTarget(
        id: "cloudscan://fixture/demo",
        url: URL(string: "cloudscan://fixture/demo")!,
        displayName: "demo@example.com",
        kind: .cloud
    )
}

/// Consumes a scan stream to completion, rethrowing whatever it throws.
private func drain(_ stream: AsyncThrowingStream<ScanProgressEvent, Error>) async throws {
    for try await _ in stream {}
}

/// A ScanEventStreaming that records which targets it was asked to scan and
/// finishes each stream immediately.
private final class RecordingStreamService: ScanEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var targetIDs: [String] = []

    var recordedTargetIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return targetIDs
    }

    func scan(target: ScanTarget, options: ScanOptions) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        lock.lock()
        targetIDs.append(target.id)
        lock.unlock()
        return AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class FakeCloudScanIntegration: CloudScanIntegrating {
    private(set) var accountTargets: [ScanTarget]
    private var subtitles: [String: String]
    private let connectMenu: [(id: String, title: String)]
    /// The target `connectAccount` should append and return.
    var nextConnectResult: ScanTarget?
    var onAccountsChanged: (() -> Void)?

    init(
        accountTargets: [ScanTarget],
        subtitles: [String: String],
        connectMenu: [(id: String, title: String)] = []
    ) {
        self.accountTargets = accountTargets
        self.subtitles = subtitles
        self.connectMenu = connectMenu
    }

    var scanService: any ScanEventStreaming { RecordingStreamService() }

    func accountSubtitle(forTargetID targetID: String) -> String? {
        subtitles[targetID]
    }

    var canConnectAccounts: Bool { !connectMenu.isEmpty }

    var connectMenuItems: [(id: String, title: String)] { connectMenu }

    func connectAccount(providerID: String) async throws -> ScanTarget {
        let target = nextConnectResult ?? makeCloudTarget()
        accountTargets.append(target)
        subtitles[target.id] = "Google Drive"
        onAccountsChanged?()
        return target
    }

    func signOut(targetID: String) async {
        accountTargets.removeAll { $0.id == targetID }
        subtitles[targetID] = nil
        onAccountsChanged?()
    }
}

/// A view model built against a throwaway snapshot cache and defaults suite,
/// so the init-time prune never touches the real cache.
private struct IsolatedModelEnvironment {
    private let cacheDirectory: URL
    private let cache: ScanSnapshotCache
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let sidebarFolderStore: SidebarFolderStore

    init() throws {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "NeodiskCloudGlueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
        defaultsSuiteName = "NeodiskCloudGlueTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        sidebarFolderStore = SidebarFolderStore(defaults: defaults)
    }

    @MainActor
    func makeModel(cloudScan: any CloudScanIntegrating) -> NeodiskViewModel {
        NeodiskViewModel(
            snapshotCache: cache,
            sidebarFolderStore: sidebarFolderStore,
            cloudScan: cloudScan
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
    }
}
