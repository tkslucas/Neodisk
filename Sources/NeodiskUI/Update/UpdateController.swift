//
//  UpdateController.swift
//  Neodisk
//
//  Owns the Sparkle updater for the packaged app. Unbundled `swift run`
//  builds (no bundle identifier) and bundles without a configured SUFeedURL
//  never create an updater — the menu item stays disabled and Settings shows
//  a note instead. See UpdateSupport for the gate; the release-side
//  requirements (EdDSA keys, appcast) live in the release docs.
//

import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    /// State for the in-window indicator; fed by the driver.
    let viewModel = UpdateViewModel()

    /// Mirrors SPUUpdater.canCheckForUpdates (KVO) for menu validation.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors SPUUpdater.automaticallyChecksForUpdates (KVO), which itself
    /// persists to user defaults under Sparkle's SUEnableAutomaticChecks key
    /// (falling back to the Info.plist value until the user decides).
    @Published private(set) var automaticallyChecksForUpdates = false

    /// True when this build can update itself at all (packaged app with an
    /// appcast feed). Views use it to disable or annotate update UI.
    let isSupported: Bool

    private var updater: SPUUpdater?
    private var driver: UpdateDriver?
    private var cancellables: Set<AnyCancellable> = []

    init(hostBundle: Bundle = .main) {
        isSupported = UpdateSupport.isSupported(in: hostBundle)
        guard isSupported else { return }

        let driver = UpdateDriver(viewModel: viewModel, hostBundle: hostBundle)
        let updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: nil
        )
        self.driver = driver

        do {
            try updater.start()
        } catch {
            // Misconfigured bundle (e.g. placeholder feed rejected by
            // Sparkle): run without updates rather than alerting on launch.
            NSLog("Neodisk: Sparkle updater failed to start: \(error.localizedDescription)")
            return
        }
        self.updater = updater

        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
            }
            .store(in: &cancellables)
    }

    /// User-initiated check (menu item / Settings button).
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Settings toggle write-through; the KVO publisher refreshes the
    /// published mirror.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }
}
