import AppKit

@MainActor
func beepUnless(_ handled: Bool) {
    if !handled { NSSound.beep() }
}
