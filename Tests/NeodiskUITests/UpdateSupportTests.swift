import Foundation
import Testing
@testable import NeodiskUI

@Suite struct UpdateSupportTests {
    private let feed = "https://github.com/tkslucas/Neodisk/releases/latest/download/appcast.xml"

    @Test func packagedAppWithFeedIsSupported() {
        #expect(UpdateSupport.isSupported(
            bundleIdentifier: "com.lucastakayasu.Neodisk", feedURLString: feed
        ))
    }

    @Test func unbundledSwiftRunIsNotSupported() {
        // `swift run` has no app bundle, hence no bundle identifier.
        #expect(!UpdateSupport.isSupported(bundleIdentifier: nil, feedURLString: feed))
        #expect(!UpdateSupport.isSupported(bundleIdentifier: "", feedURLString: feed))
    }

    @Test func missingOrEmptyFeedIsNotSupported() {
        #expect(!UpdateSupport.isSupported(
            bundleIdentifier: "com.lucastakayasu.Neodisk", feedURLString: nil
        ))
        #expect(!UpdateSupport.isSupported(
            bundleIdentifier: "com.lucastakayasu.Neodisk", feedURLString: ""
        ))
        #expect(!UpdateSupport.isSupported(
            bundleIdentifier: "com.lucastakayasu.Neodisk", feedURLString: "  \n"
        ))
    }

    @Test func malformedFeedIsNotSupported() {
        for bad in ["not a url", "appcast.xml", "file:///tmp/appcast.xml", "ftp://x/appcast.xml", "https://"] {
            #expect(!UpdateSupport.isSupported(
                bundleIdentifier: "com.lucastakayasu.Neodisk", feedURLString: bad
            ), "should reject \(bad)")
        }
    }

    @Test func feedWithSurroundingWhitespaceIsAccepted() {
        #expect(UpdateSupport.isSupported(
            bundleIdentifier: "com.lucastakayasu.Neodisk", feedURLString: " \(feed)\n"
        ))
    }

    @Test func mainBundleGateMatchesComponents() {
        // Under `swift test` the host bundle has no SUFeedURL (and typically
        // no meaningful identity for updating), so the live gate must agree
        // with the component gate and, crucially, never trap.
        let expected = UpdateSupport.isSupported(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            feedURLString: Bundle.main.object(forInfoDictionaryKey: UpdateSupport.feedURLKey) as? String
        )
        #expect(UpdateSupport.isSupported(in: .main) == expected)
    }
}

@Suite @MainActor struct UpdateViewModelHostTests {
    @Test func lastHostDisappearingUnwindsPendingState() {
        let viewModel = UpdateViewModel()
        viewModel.hostDidAppear()
        #expect(viewModel.hasIndicatorHost)

        var cancelled = false
        viewModel.state = .checking(cancel: { cancelled = true })
        viewModel.hostDidDisappear()

        #expect(!viewModel.hasIndicatorHost)
        #expect(viewModel.state.isIdle)
        #expect(cancelled)
    }

    @Test func remainingHostKeepsPendingState() {
        let viewModel = UpdateViewModel()
        viewModel.hostDidAppear()
        viewModel.hostDidAppear()

        var cancelled = false
        viewModel.state = .checking(cancel: { cancelled = true })
        viewModel.hostDidDisappear()

        #expect(viewModel.hasIndicatorHost)
        #expect(!viewModel.state.isIdle)
        #expect(!cancelled)
    }
}

@Suite struct UpdateStateTests {
    @Test func downloadingProgressFractionNeedsExpectedLength() {
        let unknown = UpdateState.downloading(received: 10, expected: nil, cancel: {})
        #expect(unknown.progressFraction == nil)

        let half = UpdateState.downloading(received: 50, expected: 100, cancel: {})
        #expect(half.progressFraction == 0.5)

        // Overshoot (server lied about Content-Length) clamps to 1.
        let over = UpdateState.downloading(received: 150, expected: 100, cancel: {})
        #expect(over.progressFraction == 1)
    }

    @Test func extractingProgressFractionIsClamped() {
        #expect(UpdateState.extracting(progress: -0.5).progressFraction == 0)
        #expect(UpdateState.extracting(progress: 0.25).progressFraction == 0.25)
        #expect(UpdateState.extracting(progress: 1.5).progressFraction == 1)
    }

    @Test func onlyIdleIsIdleAndBusyStatesSpin() {
        #expect(UpdateState.idle.isIdle)
        #expect(UpdateState.idle.title.isEmpty)

        let active: [UpdateState] = [
            .checking(cancel: {}),
            .available(version: "1.2.3", install: {}, dismiss: {}),
            .downloading(received: 0, expected: nil, cancel: {}),
            .extracting(progress: 0),
            .readyToInstall(install: {}, dismiss: {}),
            .installing,
            .upToDate,
            .failed(message: "boom", dismiss: {}),
        ]
        for state in active {
            #expect(!state.isIdle)
            #expect(!state.title.isEmpty)
        }

        #expect(UpdateState.checking(cancel: {}).isBusy)
        #expect(UpdateState.installing.isBusy)
        #expect(!UpdateState.upToDate.isBusy)
        #expect(!UpdateState.available(version: "1", install: {}, dismiss: {}).isBusy)
    }
}
