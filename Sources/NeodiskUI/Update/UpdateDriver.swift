// Routes update progress into the in-window indicator instead of Sparkle's dialogs, falling back to the
// standard driver when no window can host it. Permission prompts and post-install always use the standard ones.

import AppKit
import NeodiskKit
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
        // Shown only when SUEnableAutomaticChecks is absent from Info.plist; Neodisk ships it true, so this is
        // a defensive fallback.
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
        DiagnosticLog.app.error("update failed: \(error)")
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
