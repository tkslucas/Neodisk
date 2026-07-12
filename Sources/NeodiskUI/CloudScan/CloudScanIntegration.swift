//
//  CloudScanIntegration.swift
//  Neodisk
//
//  The seam that lets the app use CloudScan without hard-depending on
//  CloudScanKit: NeodiskViewModel and the app wiring only ever see these
//  unguarded types, so a build with CloudScanKit removed still compiles
//  (CloudScanFactory.make returns nil, the router's cloud leg is absent, and
//  no cloud UI appears). Only CloudScanModel/CloudScanFactory import the kit.
//

import Foundation
import NeodiskKit

/// What the UI needs from a live CloudScan feature: the connected-account
/// sidebar targets, the event stream cloud scans route through, and each
/// account's provider subtitle. CloudScanModel is the only conformer, present
/// only in builds that include CloudScanKit.
@MainActor
protocol CloudScanIntegrating: AnyObject {
    /// One ScanTarget per connected cloud account, for the sidebar's Cloud
    /// Drives section and the scan router's keep-list.
    var accountTargets: [ScanTarget] { get }
    /// The stream `.cloud` targets scan through, wired into the coordinator
    /// via RoutingScanService.
    var scanService: any ScanEventStreaming { get }
    /// The provider name shown under an account row ("Google Drive").
    func accountSubtitle(forTargetID targetID: String) -> String?

    /// True when at least one provider can be connected interactively (its
    /// OAuth client is configured). Drives whether the sidebar shows the
    /// Cloud Drives section and its connect button when no account exists yet.
    var canConnectAccounts: Bool { get }
    /// One entry per connectable provider: a stable provider id and the
    /// button title ("Connect Google Drive…"). Empty when nothing is
    /// configured.
    var connectMenuItems: [(id: String, title: String)] { get }
    /// Runs the provider's OAuth flow (opening the browser) and returns the
    /// new account's sidebar target. Fires `onAccountsChanged` on success.
    func connectAccount(providerID: String) async throws -> ScanTarget
    /// Revokes and forgets the account behind a cloud target, then fires
    /// `onAccountsChanged`.
    func signOut(targetID: String) async
    /// Called after the connected-account set changes (connect / sign out) so
    /// the view model can refresh its sidebar targets.
    var onAccountsChanged: (() -> Void)? { get set }
}

/// Sends `.cloud` targets to the cloud scan service and everything else to
/// the local ScanEngine — the single ScanEventStreaming the coordinator talks
/// to, so the coordinator never learns cloud scanning exists. A build without
/// CloudScanKit passes `cloudService: nil`; a stray cloud target then finishes
/// immediately with CloudScanUnavailableError instead of silently hanging.
struct RoutingScanService: ScanEventStreaming {
    let localService: any ScanEventStreaming
    let cloudService: (any ScanEventStreaming)?

    init(
        localService: any ScanEventStreaming = ScanEngine(),
        cloudService: (any ScanEventStreaming)? = nil
    ) {
        self.localService = localService
        self.cloudService = cloudService
    }

    func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        guard target.kind == .cloud else {
            return localService.scan(target: target, options: options)
        }
        guard let cloudService else {
            return AsyncThrowingStream { $0.finish(throwing: CloudScanUnavailableError()) }
        }
        return cloudService.scan(target: target, options: options)
    }
}

/// Thrown when a cloud target is scanned in a build that excluded
/// CloudScanKit — the router's cloud leg is absent.
struct CloudScanUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Cloud scanning is not included in this build."
    }
}
