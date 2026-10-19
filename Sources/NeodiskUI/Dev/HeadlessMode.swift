//
//  HeadlessMode.swift
//  Neodisk
//
//  Dev/bench hook: NEODISK_HEADLESS=1 runs the real app off-screen for
//  end-to-end performance measurement, with the NEODISK_UI_SNAPSHOT offscreen
//  machinery but no capture. Both surfaces gate on this one switch.
//

import Foundation

enum HeadlessMode {
    /// True when the app must run entirely off-screen with no Dock presence
    /// and never steal focus: either a snapshot capture (NEODISK_UI_SNAPSHOT)
    /// or a felt-time bench run (NEODISK_HEADLESS=1).
    static var isOffscreen: Bool {
        ProcessInfo.processInfo.environment["NEODISK_UI_SNAPSHOT"] != nil
            || ProcessInfo.processInfo.environment["NEODISK_HEADLESS"] == "1"
    }
}
