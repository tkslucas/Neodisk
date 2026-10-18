// File actions for the selected node: Quick Look, Reveal in Finder, Open and Copy Path.

import AppKit
import NeodiskKit

extension NeodiskViewModel {
    // MARK: - File actions

    /// Whether the node's file actions (Reveal in Finder / Open / Copy Path) apply.
    func supportsFileActions(_ node: FileNodeRecord) -> Bool {
        node.supportsFileActions
    }

    /// Whether the selection's file actions apply — enablement for the
    /// Inspect menu's Open / Reveal in Finder / Copy Path items.
    var selectionSupportsFileActions: Bool {
        selectedNode.map(supportsFileActions) ?? false
    }

    /// Previews the selection, so click-then-space works without focusing a sidebar list.
    func quickLookSelection() {
        guard let node = selectedNode else {
            NSSound.beep()
            return
        }
        QuickLookPresenter.shared.togglePreview(for: node)
    }

    /// Return-key reveal shared by the treemap and sunburst. Beeps when the
    /// selection has no on-disk counterpart to show.
    func revealSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        reveal(node)
    }

    /// Inspect > Open for the selection. Beeps when the selection has no
    /// on-disk counterpart (backstop; the menu item is disabled then).
    func openSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        open(node)
    }

    /// Inspect > Copy Path for the selection, with the same beep backstop.
    func copyPathOfSelection() {
        guard let node = selectedNode, supportsFileActions(node) else {
            NSSound.beep()
            return
        }
        copyPath(node)
    }

    func reveal(_ node: FileNodeRecord) {
        SystemIntegration.reveal(node.url)
    }

    func open(_ node: FileNodeRecord) {
        do {
            try SystemIntegration.open(node.url)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func copyPath(_ node: FileNodeRecord) {
        do {
            try SystemIntegration.copyPath(node.url)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

}
