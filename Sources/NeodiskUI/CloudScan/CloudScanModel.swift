//
//  CloudScanModel.swift
//  Neodisk
//
//  The live CloudScan integration. Absent whenever CloudScanKit is excluded
//  from the build (nothing references the type there), so the whole file is
//  `#if canImport(CloudScanKit)` with no #else.
//

#if canImport(CloudScanKit)
import Foundation
import NeodiskKit
import CloudScanKit

/// Owns the CloudScanService and its providers, turns connected accounts into
/// sidebar targets, and adapts the service's `scan(target:)` into the
/// ScanEventStreaming the router expects.
@MainActor
final class CloudScanModel: CloudScanIntegrating {
    private let service: CloudScanService
    private let providers: [any CloudProvider]
    /// The provider connect actions to offer, in menu order. Empty when no
    /// provider's OAuth client is configured.
    private let connectMenu: [(id: String, title: String)]
    /// How the provider opens the consent page. Injected so this file never
    /// imports AppKit; the factory supplies an NSWorkspace-backed closure.
    private let openURL: @Sendable (URL) -> Void

    var onAccountsChanged: (() -> Void)?

    init(
        service: CloudScanService,
        providers: [any CloudProvider],
        connectMenu: [(id: String, title: String)] = [],
        openURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.service = service
        self.providers = providers
        self.connectMenu = connectMenu
        self.openURL = openURL
    }

    var accountTargets: [ScanTarget] {
        providers.flatMap { provider in
            let accounts = (try? provider.restoreAccounts()) ?? []
            return accounts.compactMap { account in
                CloudTargetID.target(
                    providerID: account.providerID,
                    accountID: account.accountID,
                    displayName: account.email
                )
            }
        }
    }

    func accountSubtitle(forTargetID targetID: String) -> String? {
        guard let parsed = CloudTargetID.parse(targetID),
              let provider = service.provider(forID: parsed.providerID) else {
            return nil
        }
        return provider.displayName
    }

    var scanService: any ScanEventStreaming {
        CloudScanServiceAdapter(service: service)
    }

    var canConnectAccounts: Bool { !connectMenu.isEmpty }

    var connectMenuItems: [(id: String, title: String)] { connectMenu }

    func connectAccount(providerID: String) async throws -> ScanTarget {
        guard let provider = service.provider(forID: providerID) else {
            throw CloudScanError.invalidTarget(providerID)
        }
        let account = try await provider.authorize(openURL: openURL)
        guard let target = CloudTargetID.target(
            providerID: account.providerID,
            accountID: account.accountID,
            displayName: account.email
        ) else {
            throw CloudScanError.invalidTarget(account.accountID)
        }
        onAccountsChanged?()
        return target
    }

    func signOut(targetID: String) async {
        guard let parsed = CloudTargetID.parse(targetID),
              let provider = service.provider(forID: parsed.providerID) else {
            return
        }
        if let account = (try? provider.restoreAccounts())?.first(where: {
            $0.accountID == parsed.accountID
        }) {
            try? await provider.signOut(account)
        }
        onAccountsChanged?()
    }
}

/// Bridges CloudScanService.scan(target:) — which takes no ScanOptions — to
/// the ScanEventStreaming contract the coordinator and router speak.
private struct CloudScanServiceAdapter: ScanEventStreaming {
    let service: CloudScanService

    func scan(
        target: ScanTarget,
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanProgressEvent, Error> {
        service.scan(target: target)
    }
}
#endif
