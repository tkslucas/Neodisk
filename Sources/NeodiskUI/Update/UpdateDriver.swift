//
//  UpdateDriver.swift
//  Neodisk
//
//  SPUUserDriver that routes update progress into the unobtrusive in-window
//  indicator (UpdateViewModel) instead of Sparkle's dialog windows, in the
//  spirit of Ghostty's UpdateDriver. When no main window can host the
//  indicator, every step falls back to the wrapped SPUStandardUserDriver so
//  flows are never invisible. First-launch permission prompts and the
//  post-install acknowledgement always use the standard (Sparkle-localized)
//  dialogs.
//

import AppKit
import Sparkle

@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    private let standard: SPUStandardUserDriver

    init(viewModel: UpdateViewModel, hostBundle: Bundle) {
        self.viewModel = viewModel
        self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    private var hasIndicatorHost: Bool { viewModel.hasIndicatorHost }

    // MARK: - Permission

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        // Sparkle's own consent dialog (only shown when SUEnableAutomaticChecks
        // is absent from Info.plist). Kept as a defensive fallback; Neodisk
        // ships the key as true — checks are on by default and the Settings
        // toggle is the opt-out. Installing always needs a user click.
        standard.show(request, reply: reply)
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        viewModel.state = .checking(cancel: cancellation)
        if !hasIndicatorHost {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        viewModel.state = .available(
            version: appcastItem.displayVersionString,
            install: { reply(.install) },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
                reply(.dismiss)
            }
        )
        if !hasIndicatorHost {
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The indicator links to GitHub releases implicitly via the appcast;
        // no in-app release notes UI.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // See showUpdateReleaseNotes.
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if hasIndicatorHost {
            viewModel.state = .upToDate
            // The pill persists until the user dismisses it; Sparkle can
            // end its session now so a re-check is possible meanwhile.
            acknowledgement()
        } else {
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if hasIndicatorHost {
            viewModel.state = .failed(
                message: error.localizedDescription,
                dismiss: { [weak viewModel] in viewModel?.state = .idle }
            )
            // The indicator keeps showing the failure; Sparkle can move on.
            acknowledgement()
        } else {
            viewModel.state = .idle
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }

    // MARK: - Download and install

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        viewModel.state = .downloading(received: 0, expected: nil, cancel: cancellation)
        if !hasIndicatorHost {
            standard.showDownloadInitiated(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if case .downloading(_, _, let cancel) = viewModel.state {
            viewModel.state = .downloading(
                received: 0, expected: expectedContentLength, cancel: cancel
            )
        }
        if !hasIndicatorHost {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if case .downloading(let received, let expected, let cancel) = viewModel.state {
            viewModel.state = .downloading(
                received: received + length, expected: expected, cancel: cancel
            )
        }
        if !hasIndicatorHost {
            standard.showDownloadDidReceiveData(ofLength: length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(progress: 0)
        if !hasIndicatorHost {
            standard.showDownloadDidStartExtractingUpdate()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(progress: progress)
        if !hasIndicatorHost {
            standard.showExtractionReceivedProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        viewModel.state = .readyToInstall(
            install: { reply(.install) },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
                reply(.dismiss)
            }
        )
        if !hasIndicatorHost {
            standard.showReady(toInstallAndRelaunch: reply)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        viewModel.state = .installing
        if !hasIndicatorHost {
            standard.showInstallingUpdate(
                withApplicationTerminated: applicationTerminated,
                retryTerminatingApplication: retryTerminatingApplication
            )
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        viewModel.state = .idle
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        if !hasIndicatorHost {
            standard.showUpdateInFocus()
        }
    }

    func dismissUpdateInstallation() {
        switch viewModel.state {
        case .upToDate, .failed:
            // Sparkle ends its session right after these are acknowledged;
            // the result pill persists until the user dismisses it.
            break
        default:
            viewModel.state = .idle
        }
        standard.dismissUpdateInstallation()
    }
}
