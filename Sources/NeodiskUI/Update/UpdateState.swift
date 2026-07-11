//
//  UpdateState.swift
//  Neodisk
//
//  Sparkle-free model for the in-window update indicator (in the spirit of
//  Ghostty's UpdateViewModel): the driver maps Sparkle callbacks onto this
//  state machine, and the toolbar indicator + popover render it. Closures
//  wrap Sparkle's replies so views never touch Sparkle types.
//

import Combine
import Foundation

@MainActor
final class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle

    /// Number of live main windows that can host the toolbar indicator.
    /// ContentView increments/decrements this; when it is zero the driver
    /// falls back to Sparkle's standard dialog UI so update flows are never
    /// invisible (e.g. menu-triggered check with the window closed).
    var indicatorHostCount = 0

    var hasIndicatorHost: Bool { indicatorHostCount > 0 }

    func hostDidAppear() {
        indicatorHostCount += 1
    }

    /// When the last host window closes, unwind whatever update state is
    /// pending (answering Sparkle's outstanding reply) so the session does
    /// not dangle invisibly; a later manual check falls back to the
    /// standard dialog driver.
    func hostDidDisappear() {
        indicatorHostCount -= 1
        guard indicatorHostCount <= 0, !state.isIdle else { return }
        state.cancel()
        state = .idle
    }
}

enum UpdateState {
    case idle
    case checking(cancel: () -> Void)
    case available(version: String, install: () -> Void, dismiss: () -> Void)
    case downloading(received: UInt64, expected: UInt64?, cancel: () -> Void)
    case extracting(progress: Double)
    case readyToInstall(install: () -> Void, dismiss: () -> Void)
    case installing
    /// The check found nothing. Sparkle is acknowledged immediately by the
    /// driver, so this state can persist until the user dismisses the pill.
    case upToDate
    case failed(message: String, dismiss: () -> Void)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// Short localized status for the toolbar indicator.
    var title: String {
        switch self {
        case .idle:
            return ""
        case .checking:
            return NSLocalizedString("Checking for Updates…", comment: "Update indicator, checking the appcast")
        case .available:
            return NSLocalizedString("Update Available", comment: "Update indicator, a new version exists")
        case .downloading:
            return NSLocalizedString("Downloading Update…", comment: "Update indicator, download in progress")
        case .extracting:
            return NSLocalizedString("Preparing Update…", comment: "Update indicator, extracting the archive")
        case .readyToInstall:
            return NSLocalizedString("Ready to Install", comment: "Update indicator, update downloaded and waiting")
        case .installing:
            return NSLocalizedString("Installing Update…", comment: "Update indicator, installer running")
        case .upToDate:
            return NSLocalizedString("You're up to date.", comment: "Update indicator, no update found")
        case .failed:
            return NSLocalizedString("Update Error", comment: "Update indicator, the update failed")
        }
    }

    /// Determinate progress for the popover, when the state has one.
    var progressFraction: Double? {
        switch self {
        case .downloading(let received, let expected, _):
            guard let expected, expected > 0 else { return nil }
            return min(Double(received) / Double(expected), 1)
        case .extracting(let progress):
            return min(max(progress, 0), 1)
        default:
            return nil
        }
    }

    /// SF Symbol for states that are not spinner-backed.
    var symbolName: String? {
        switch self {
        case .available, .readyToInstall:
            return "shippingbox.fill"
        case .upToDate:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return nil
        }
    }

    /// True while Sparkle is actively working (spinner in the indicator).
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .installing:
            return true
        default:
            return false
        }
    }

    /// Dev/testing hook (NEODISK_UPDATE_STATE): builds a representative
    /// non-idle state with inert closures so headless snapshots can show the
    /// toolbar pill without driving a real Sparkle check. Not used in
    /// shipping flows.
    static func devState(named name: String) -> UpdateState? {
        let noop: () -> Void = {}
        switch name {
        case "checking":
            return .checking(cancel: noop)
        case "available":
            return .available(version: "2.99.0", install: noop, dismiss: noop)
        case "downloading":
            return .downloading(received: 4_200_000, expected: 9_000_000, cancel: noop)
        case "readyToInstall":
            return .readyToInstall(install: noop, dismiss: noop)
        case "upToDate":
            return .upToDate
        case "failed":
            return .failed(message: "Update check failed.", dismiss: noop)
        default:
            return nil
        }
    }

    /// Answers the state's outstanding Sparkle reply with the dismissive
    /// choice, for when the indicator can no longer be shown.
    func cancel() {
        switch self {
        case .idle, .extracting, .installing, .upToDate:
            break
        case .checking(let cancel):
            cancel()
        case .available(_, _, let dismiss):
            dismiss()
        case .downloading(_, _, let cancel):
            cancel()
        case .readyToInstall(_, let dismiss):
            dismiss()
        case .failed(_, let dismiss):
            dismiss()
        }
    }
}
