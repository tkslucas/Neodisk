// contextMenu(forSelectionType:primaryAction:) is the only way to add double-click to a macOS List
// without breaking selection: every SwiftUI tap gesture swallows the mouse-down NSTableView needs.

import AppKit
import SwiftUI
import NeodiskKit

// MARK: - AppKit variant

/// NSMenuItem that runs a closure; NSMenu's target/action plumbing needs an
/// object to point at, and the item itself is the natural owner.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem does not support NSCoder")
    }

    @objc private func invoke() {
        handler()
    }
}

extension NSMenu {
    /// `includeCleanup: false` for a "smaller items" cell, which stands for its folder but mustn't offer to collect
    /// it (and acts on that folder alone).
    @MainActor
    static func fileNodeActions(
        for node: FileNodeRecord, model: NeodiskViewModel, includeCleanup: Bool = true
    ) -> NSMenu? {
        guard model.supportsFileActions(node) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addFileNodeActionItems(for: node, model: model, includeCleanup: includeCleanup)
        return menu
    }

    /// Right-clicking an item of a multi-selection acts on the whole selection; any other item, on itself alone
    /// (the macOS rule). The flat statistics lists leave out the contents-expansion item.
    @MainActor
    func addFileNodeActionItems(
        for node: FileNodeRecord, model: NeodiskViewModel, includeExpandContents: Bool = true,
        includeCleanup: Bool = true
    ) {
        let nodes = includeCleanup ? model.actionTargets(clicked: node) : [node]
        addItem(ClosureMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "File node context menu")) { model.reveal(nodes) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Open", comment: "File node context menu")) { model.open(nodes) })
        let copyTitle = nodes.count > 1
            ? NSLocalizedString("Copy Paths", comment: "File node context menu, several items")
            : NSLocalizedString("Copy Path", comment: "File node context menu")
        addItem(ClosureMenuItem(title: copyTitle) { model.copyPaths(nodes) })
        if includeExpandContents, nodes.count == 1, let expansion = model.contentsExpansion(for: node) {
            addItem(.separator())
            let item = ClosureMenuItem(title: NSLocalizedString(expansion.menuTitleKey, comment: "File node context menu")) { model.expandNodeContents(node) }
            item.isEnabled = model.canRefreshSubtree
            addItem(item)
        }
        if includeCleanup { addCleanupItem(for: nodes, model: model) }
    }

    /// "Add to Cleanup" / "Remove 3 Items from Cleanup"…; a refused item stays disabled with its reason as the tooltip.
    @MainActor
    func addCleanupItem(for nodes: [FileNodeRecord], model: NeodiskViewModel) {
        guard model.cleanup.isEnabled else { return }
        addItem(.separator())
        let item = ClosureMenuItem(title: model.cleanupMenuTitle(for: nodes)) { model.cleanup.toggle(nodes) }
        item.isEnabled = model.canToggleCleanup(for: nodes)
        item.toolTip = model.cleanupMenuHelp(for: nodes)
        addItem(item)
    }
}
