//
//  Feedback.swift
//  Neodisk
//
//  Tiny audible-feedback helper shared by the keyboard handlers (treemap,
//  sunburst, menu commands): drill and reveal actions beep when there is
//  nowhere to go.
//

import AppKit

@MainActor
func beepUnless(_ handled: Bool) {
    if !handled { NSSound.beep() }
}
