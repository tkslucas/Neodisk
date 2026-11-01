// The app model as the canvas sees it: the shared names come from ShellModel; these are the window's parts.

import Foundation
import NeodiskAppModel
import NeodiskKit
import WinSDK

extension ShellModel: VizCanvasModel {
    /// The map leaves free and hidden space out until the statistics that explain them exist on Windows.
    var vizFreeSpaceBytes: Int64? { nil }
    var vizHiddenSpaceBytes: Int64? { nil }

    func vizShowContextMenu(atScreen point: POINT, includeTrash: Bool) {
        controller?.showItemMenu(atScreen: point)
    }

    func vizShowInExplorer(nodeID: String) {
        guard let node = store?.node(id: nodeID) else { return }
        FileActions.showInExplorer(node.path)
    }

    /// The status bar follows the hovered item itself.
    func vizStatusText(_ text: String?) {}

    /// The window's keys reach it before the canvas (the message loop's first look).
    func vizHandleKey(vk: UInt32, ctrl: Bool, shift: Bool, alt: Bool) -> Bool { false }
}
