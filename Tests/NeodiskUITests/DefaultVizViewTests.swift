//
//  DefaultVizViewTests.swift
//  Neodisk
//
//  The default-view launch preference: creating AppPreferences (= launch)
//  applies the chosen default over the persisted current-view pair, while
//  "last viewed" (the default) keeps whatever the previous session left.
//

import Foundation
import Testing
@testable import NeodiskUI

@Suite @MainActor struct DefaultVizViewTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "DefaultVizViewTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func lastViewedRestoresPreviousSessionsView() {
        withSuite { defaults in
            let previous = AppPreferences(defaults: defaults)
            previous.vizViewMode = .sunburst
            previous.treemapStyle = .flat

            let relaunched = AppPreferences(defaults: defaults)
            #expect(relaunched.defaultVizView == .lastViewed)
            #expect(relaunched.vizViewMode == .sunburst)
            #expect(relaunched.treemapStyle == .flat)
        }
    }

    @Test func explicitDefaultOverridesPersistedViewAtLaunch() {
        withSuite { defaults in
            let previous = AppPreferences(defaults: defaults)
            previous.defaultVizView = .flatTreemap
            previous.vizViewMode = .sunburst
            previous.treemapStyle = .cushion

            let relaunched = AppPreferences(defaults: defaults)
            #expect(relaunched.vizViewMode == .treemap)
            #expect(relaunched.treemapStyle == .flat)
        }
    }

    @Test func sunburstDefaultLeavesTreemapStyleAlone() {
        withSuite { defaults in
            let previous = AppPreferences(defaults: defaults)
            previous.defaultVizView = .sunburst
            previous.vizViewMode = .treemap
            previous.treemapStyle = .flat

            let relaunched = AppPreferences(defaults: defaults)
            #expect(relaunched.vizViewMode == .sunburst)
            #expect(relaunched.treemapStyle == .flat)
        }
    }

    @Test func restoreDefaultsResetsDefaultView() {
        withSuite { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.defaultVizView = .cushionTreemap
            preferences.restoreDefaults()
            #expect(preferences.defaultVizView == .lastViewed)
        }
    }
}
