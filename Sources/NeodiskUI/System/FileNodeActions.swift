// contextMenu(forSelectionType:primaryAction:) is the only way to add double-click to a macOS List
// without breaking selection: every SwiftUI tap gesture swallows the mouse-down NSTableView needs.

import AppKit
import SwiftUI
import NeodiskKit

extension View {
    /// Double-click reveals in Finder, like a treemap cell. No-ops for nodes without file actions
    /// (the synthetic "System Data" node).
    func fileNodeActions(
        model: NeodiskViewModel, includeExpandContents: Bool = false
    ) -> some View {
        contextMenu(forSelectionType: String.self) { ids in
            if let node = ids.first.flatMap({ model.store?.node(id: $0) }),
               model.supportsFileActions(node) {
                Button("Reveal in Finder") { model.reveal(node) }
                Button("Open") { model.open(node) }
                Button("Copy Path") { model.copyPath(node) }
                if includeExpandContents, let expansion = model.contentsExpansion(for: node) {
                    Divider()
                    Button(LocalizedStringKey(expansion.menuTitleKey)) { model.expandNodeContents(node) }
                        .disabled(!model.canRefreshSubtree)
                }
                if model.cleanup.isEnabled {
                    Divider()
                    Button(LocalizedStringKey(model.cleanupMenuTitle(for: node))) { model.cleanup.toggle(node) }
                        .disabled(!model.canToggleCleanup(for: node))
                        .help(model.cleanup.refusalReason(for: node) ?? "")
                }
            }
        } primaryAction: { ids in
            guard let id = ids.first,
                  let node = model.store?.node(id: id),
                  model.supportsFileActions(node) else { return }
            model.select(id)
            model.reveal(node)
        }
    }
}

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
    /// Keep in lockstep with the SwiftUI `fileNodeActions` above. Nil for nodes without file actions.
    /// `includeCleanup: false` for a "smaller items" cell, which stands for its folder in the menu but shouldn't
    /// offer to collect the whole folder.
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

    /// The flat statistics lists leave out the contents-expansion item, as their SwiftUI predecessors did.
    @MainActor
    func addFileNodeActionItems(
        for node: FileNodeRecord, model: NeodiskViewModel, includeExpandContents: Bool = true,
        includeCleanup: Bool = true
    ) {
        addItem(ClosureMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "File node context menu")) { model.reveal(node) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Open", comment: "File node context menu")) { model.open(node) })
        addItem(ClosureMenuItem(title: NSLocalizedString("Copy Path", comment: "File node context menu")) { model.copyPath(node) })
        if includeExpandContents, let expansion = model.contentsExpansion(for: node) {
            addItem(.separator())
            let item = ClosureMenuItem(title: NSLocalizedString(expansion.menuTitleKey, comment: "File node context menu")) { model.expandNodeContents(node) }
            item.isEnabled = model.canRefreshSubtree
            addItem(item)
        }
        if includeCleanup { addCleanupItem(for: node, model: model) }
    }

    /// "Add to Cleanup" / "Remove from Cleanup"; a refused item stays disabled with its reason as the tooltip.
    @MainActor
    func addCleanupItem(for node: FileNodeRecord, model: NeodiskViewModel) {
        guard model.cleanup.isEnabled else { return }
        addItem(.separator())
        let item = ClosureMenuItem(
            title: NSLocalizedString(model.cleanupMenuTitle(for: node), comment: "File node context menu")
        ) { model.cleanup.toggle(node) }
        item.isEnabled = model.canToggleCleanup(for: node)
        item.toolTip = model.cleanup.refusalReason(for: node)
        addItem(item)
    }
}
