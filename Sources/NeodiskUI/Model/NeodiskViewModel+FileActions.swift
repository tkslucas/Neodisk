// File actions for the selection or a clicked item: Quick Look, Reveal in Finder, Open, Copy Path and Cleanup.

import AppKit
import NeodiskKit

extension NeodiskViewModel {
    // MARK: - File actions

    /// Whether the node's file actions (Reveal in Finder / Open / Copy Path) apply.
    func supportsFileActions(_ node: FileNodeRecord) -> Bool {
        node.supportsFileActions
    }

    /// The selected items, in the order they were picked.
    var selectedNodes: [FileNodeRecord] {
        store.map { selection.nodes(in: $0) } ?? []
    }

    /// The status line's numbers for a multi-selection.
    struct SelectionSummary: Equatable {
        let count: Int
        /// Items inside another selected item count once, with their folder.
        let totalSize: Int64
        /// Selected items in Cleanup, alone or with their folder.
        let inCleanup: Int
    }

    var selectionSummary: SelectionSummary? {
        guard let store, !selection.isEmpty else { return nil }
        let nodes = selection.nodes(in: store)
        let totalSize = selection.topLevelIDs(in: store)
            .reduce(Int64(0)) { $0 &+ (store.node(id: $1)?.allocatedSize ?? 0) }
        let inCleanup = cleanup.isEmpty && !cleanup.isMoving ? 0 : nodes.count { cleanup.mark(for: $0.id).isMarked }
        return SelectionSummary(count: nodes.count, totalSize: totalSize, inCleanup: inCleanup)
    }

    /// What a context menu on `node` acts on: the whole selection when `node` is in it, else only `node`
    /// (the selection stays as it is).
    func actionTargets(clicked node: FileNodeRecord) -> [FileNodeRecord] {
        guard selection.isMultiple, selection.contains(node.id), let store else { return [node] }
        return selection.nodes(in: store).filter(supportsFileActions)
    }

    /// The selection's items that file actions apply to.
    private var actionableSelection: [FileNodeRecord] {
        selectedNodes.filter(supportsFileActions)
    }

    /// Whether the selection's file actions apply — enablement for the
    /// Inspect menu's Open / Reveal in Finder / Copy Path items.
    var selectionSupportsFileActions: Bool {
        selection.isMultiple ? !actionableSelection.isEmpty : selectedNode.map(supportsFileActions) ?? false
    }

    /// Previews the selection, so click-then-space works without focusing a sidebar list.
    func quickLookSelection() {
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }
        QuickLookPresenter.shared.togglePreview(for: selectedNodes, current: selectedNode)
    }

    /// Return-key reveal shared by the treemap and sunburst. Beeps when the
    /// selection has no on-disk counterpart to show.
    func revealSelection() {
        perform(on: actionableSelection, reveal)
    }

    /// Inspect > Open for the selection. Beeps when the selection has no
    /// on-disk counterpart (backstop; the menu item is disabled then).
    func openSelection() {
        perform(on: actionableSelection, open)
    }

    /// Inspect > Copy Path for the selection, with the same beep backstop.
    /// Edit > Copy (⌘C) in a list: the selected items as files, as Finder copies them (pasting in Finder
    /// copies them; nothing here moves). False when nothing selected can be copied.
    @discardableResult
    func copySelection() -> Bool {
        let nodes = actionableSelection
        guard !nodes.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(nodes.map { $0.url as NSURL })
    }

    func copyPathOfSelection() {
        perform(on: actionableSelection, copyPaths)
    }

    private func perform(on nodes: [FileNodeRecord], _ action: ([FileNodeRecord]) -> Void) {
        guard !nodes.isEmpty else {
            NSSound.beep()
            return
        }
        action(nodes)
    }

    // MARK: - Cleanup

    /// "Add to Cleanup", "Remove 3 Items from Cleanup"…, localized.
    func cleanupMenuTitle(for nodes: [FileNodeRecord]) -> String {
        switch cleanup.toggle(for: nodes) {
        case .remove(let ids) where ids.count > 1:
            String(format: NSLocalizedString("Remove %lld Items from Cleanup", comment: "Menu item for several items"), ids.count)
        case .remove:
            NSLocalizedString("Remove from Cleanup", comment: "File node context menu")
        case .add(let ids) where ids.count > 1:
            String(format: NSLocalizedString("Add %lld Items to Cleanup", comment: "Menu item for several items"), ids.count)
        case .add, .none:
            NSLocalizedString("Add to Cleanup", comment: "File node context menu")
        }
    }

    /// Something inside a collected folder is already in: it can't be added or removed on its own.
    func canToggleCleanup(for nodes: [FileNodeRecord]) -> Bool {
        if nodes.count == 1, let node = nodes.first {
            switch cleanup.mark(for: node.id) {
            case .collected: return !cleanup.isMoving
            case .none: return cleanup.canCollect(node)
            case .inside, .moving: return false
            }
        }
        switch cleanup.toggle(for: nodes) {
        case .add: return !cleanup.isMoving && cleanup.unavailableReason == nil
        case .remove: return !cleanup.isMoving
        case .none: return false
        }
    }

    /// Why the Cleanup menu item is off for these items, or nil.
    func cleanupMenuHelp(for nodes: [FileNodeRecord]) -> String? {
        if nodes.count == 1, let node = nodes.first {
            let mark = cleanup.mark(for: node.id)
            return mark == .inside || mark == .moving ? mark.hoverText : cleanup.refusalReason(for: node)
        }
        switch cleanup.toggle(for: nodes) {
        case .add: return cleanup.unavailableReason
        case .remove: return nil
        case .none:
            return nodes.contains { cleanup.mark(for: $0.id) == .moving }
                ? CleanupModel.Mark.moving.hoverText : CleanupModel.Mark.inside.hoverText
        }
    }

    /// Inspect > Add to Cleanup (⌘⌫). While a text field is being edited the key keeps its text meaning
    /// (delete to the start of the line), since menu shortcuts run before the field sees the key.
    func toggleCleanupForSelection() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.deleteToBeginningOfLine(nil)
            return
        }
        let nodes = selectedNodes
        guard !nodes.isEmpty else {
            NSSound.beep()
            return
        }
        cleanup.toggle(nodes)
    }

    func reveal(_ nodes: [FileNodeRecord]) {
        SystemIntegration.reveal(nodes.map(\.url))
    }

    func open(_ nodes: [FileNodeRecord]) {
        for node in nodes { open(node) }
    }

    func copyPaths(_ nodes: [FileNodeRecord]) {
        do {
            try SystemIntegration.copyPaths(nodes.map(\.url))
        } catch {
            actionErrorMessage = error.localizedDescription
        }
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
