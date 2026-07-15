//
//  CloudAccountsModel.swift
//  Neodisk
//
//  The sidebar's connected cloud-drive accounts: the CloudScan integration
//  handle, the account list, and the connect / sign-out flows. Owned by
//  NeodiskViewModel as `model.cloudAccounts`; empty and inert in builds
//  without the CloudScan feature.
//

import Foundation
import Observation
import NeodiskKit

@MainActor
@Observable
final class CloudAccountsModel {
    /// Connected remote cloud-drive accounts (CloudScan), shown in the
    /// sidebar's "Cloud Drives" section. Seeded once at init; reassigned on
    /// every connect or sign-out, which fires observation for the sidebar.
    private(set) var accounts: [ScanTarget] = []

    /// The CloudScan integration, or nil in builds without the feature. Owns
    /// the account credentials and the cloud scan stream; the sidebar reads
    /// subtitles and connect menu items straight from it.
    @ObservationIgnored let integration: (any CloudScanIntegrating)?

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let snapshotCache: ScanSnapshotCache
    /// Back-reference for the flows that reach the wider model (starting a
    /// scan after connect, the action-error alert, the cache index) — the
    /// same idiom DiffModel and ChangesModel use. Assigned right after init.
    @ObservationIgnored weak var model: NeodiskViewModel?

    init(
        coordinator: ScanCoordinator,
        snapshotCache: ScanSnapshotCache,
        integration: (any CloudScanIntegrating)?
    ) {
        self.coordinator = coordinator
        self.snapshotCache = snapshotCache
        self.integration = integration
        // Seed before the view model computes its snapshot keep-list, so
        // persisted cloud scans survive the launch prune.
        accounts = integration?.accountTargets ?? []
        // Refresh the sidebar's cloud rows whenever an account is connected
        // or signed out.
        self.integration?.onAccountsChanged = { [weak self] in
            self?.refreshAccounts()
        }
    }

    /// Re-reads the connected cloud accounts after a connect or sign-out.
    private func refreshAccounts() {
        accounts = integration?.accountTargets ?? []
    }

    /// Runs the provider's OAuth flow (opening the browser) and, on success,
    /// scans the new account. Failures surface through the standard action
    /// alert.
    func connect(providerID: String) {
        guard let integration else { return }
        Task { [weak self] in
            do {
                let target = try await integration.connectAccount(providerID: providerID)
                self?.model?.startScan(target)
            } catch {
                self?.model?.actionErrorMessage = error.localizedDescription
            }
        }
    }

    /// Signs out of a connected cloud account: revokes and forgets its
    /// credentials, drops its cached scan, and clears the display if that
    /// account is what's on screen.
    func signOut(targetID: String) {
        guard let integration else { return }
        let wasDisplayed = coordinator.selectedTarget?.id == targetID
        Task { [weak self, snapshotCache] in
            await integration.signOut(targetID: targetID)
            await snapshotCache.removeSnapshot(forTargetID: targetID)
            guard let self else { return }
            self.model?.session.removeCachedScanInfo(forTargetID: targetID)
            self.coordinator.forgetRecentSnapshot(forTargetID: targetID)
            if wasDisplayed {
                self.coordinator.clearScan()
            }
        }
    }
}
